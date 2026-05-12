#!/usr/bin/env node
/**
 * SSDC → Stripe Treasury payout bridge — fiat off-ramp.
 *
 * Pairs with bridge-stripe-to-ssdc.mjs (the on-ramp). Together they close
 * the full real-money loop:
 *
 *   bank ──► Stripe webhook ──► SSDC mint ──► OrderEscrow ──► seller wallet
 *                                                                    │
 *   bank ◄── Stripe Treasury ◄── SSDC pulled ◄── signed payout request ┘
 *
 * Flow on this side:
 *   1. Seller pre-approves the bridge as an SSDC spender (one-shot).
 *   2. Seller signs a payout request (off-chain, with their EVM wallet key).
 *   3. POSTs the signed request to /payout.
 *   4. Bridge verifies the signature, pulls SSDC via transferFrom into a
 *      bridge-controlled treasury, returns a Stripe-Treasury-shaped payout
 *      intent with ETA + bank-account last4.
 *   5. In production, a settlement worker would finalize the payout via
 *      Stripe Treasury's `OutboundPayment.create` (or ACH directly) and
 *      mark the payout `posted` once it lands.
 *
 * The /payout response shape mirrors Stripe's `OutboundPayment` object so
 * downstream consumers can ingest it without knowing this isn't yet a real
 * Stripe Treasury endpoint.
 */

import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import {
  JsonRpcProvider, Wallet, Contract,
  parseUnits, formatUnits, getAddress, getBytes, verifyMessage,
  keccak256, toUtf8Bytes,
} from 'ethers';

const PORT = Number(process.env.PORT || 4243);
const RPC_URL = process.env.RPC_URL || 'http://localhost:8545';
const REQUEST_TTL_SECS = 5 * 60;  // signed payout requests expire in 5 minutes
const MIN_PAYOUT_USD = 1;
const MAX_PAYOUT_USD = 1_000_000;

// Symmetric to the on-ramp: same five currencies. Each ISO code maps to a
// symbol used in the canonical message and a `minorUnits` factor used by the
// Stripe Treasury OutboundPayment shape (Stripe's `amount` is in minor units
// — cents for most, but JPY/KRW are zero-decimal so the unit IS the yen).
export const SUPPORTED_OUTPUT_CURRENCIES = {
  USD: { symbol: '$', minorUnits: 100, isoLower: 'usd' },
  EUR: { symbol: '€', minorUnits: 100, isoLower: 'eur' },
  GBP: { symbol: '£', minorUnits: 100, isoLower: 'gbp' },
  JPY: { symbol: '¥', minorUnits: 1,   isoLower: 'jpy' },
  MXN: { symbol: '$', minorUnits: 100, isoLower: 'mxn' },
};

function formatAmountForMessage(amount, currency) {
  const c = SUPPORTED_OUTPUT_CURRENCIES[currency];
  if (!c) throw new Error(`unsupported currency ${currency}`);
  // Zero-decimal currencies (JPY): integer; otherwise two decimals. Keep
  // locale OUT of formatting so the message is byte-deterministic.
  return c.minorUnits === 1
    ? `${c.symbol}${Math.round(Number(amount))}`
    : `${c.symbol}${Number(amount).toFixed(2)}`;
}

// ─── Locate deployed contracts ────────────────────────────────────────────
// Reads from the repo's own broadcast log produced by `forge script DeployLocal`.
// Override with BROADCAST_LOG=/abs/path/to/run-latest.json. The lookup is LAZY
// (only on bridge start) so tests can import the pure functions on a machine
// with no deploy yet.
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const __here = dirname(fileURLToPath(import.meta.url));
const broadcastLog = process.env.BROADCAST_LOG
  || resolve(__here, '../contracts/broadcast/DeployLocal.s.sol/84532001/run-latest.json');
const NONCE_DIR = process.env.PAYOUT_NONCE_DIR
  || resolve(__here, '../stack/.run/payout-nonces');

let _addrs = null;
function loadAddresses() {
  if (_addrs) return _addrs;
  const log = JSON.parse(fs.readFileSync(broadcastLog, 'utf-8'));
  const proxies = log.transactions.filter((t) => t.contractName === 'ERC1967Proxy');
  _addrs = {
    ssdcProxy: proxies[3].contractAddress,
    fxOracleAddr: log.transactions.find((t) => t.contractName === 'FxOracle')?.contractAddress,
  };
  return _addrs;
}

// Bridge treasury — receives SSDC pulled from sellers, then settles with the
// real banking layer. anvil[6] for the demo.
const BRIDGE_TREASURY_KEY = process.env.BRIDGE_TREASURY_KEY
  || '0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e';

const provider = new JsonRpcProvider(RPC_URL);
const bridge = new Wallet(BRIDGE_TREASURY_KEY, provider);

const SSDC_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function decimals() pure returns (uint8)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function transferFrom(address from, address to, uint256 amount) returns (bool)',
];
let _ssdc, _fx;
function getSsdcContract() {
  if (_ssdc) return _ssdc;
  _ssdc = new Contract(loadAddresses().ssdcProxy, SSDC_ABI, bridge);
  return _ssdc;
}

// FxOracle — used for non-USD payouts to convert seller-requested amount in
// their currency into the SSDC amount the bridge must pull. Same oracle the
// on-ramp reads, so on-ramp + off-ramp are auditable against the same rates.
const FX_ABI = [
  'function isFresh(bytes32 pair) view returns (bool)',
  'function convert(bytes32 pair, uint256 amountIn) view returns (uint256 amountOut, uint256 rate, uint64 updatedAt)',
];
function getFxContract() {
  if (_fx !== undefined) return _fx;
  const addr = loadAddresses().fxOracleAddr;
  _fx = addr ? new Contract(addr, FX_ABI, provider) : null;
  return _fx;
}

// Resolve how many SSDC (1e18) to pull for a given amount in `currency`.
// USD passes through 1:1. Non-USD reads `<CUR>/ssUSD` from the FxOracle.
async function resolveSsdcAmount(amount, currency) {
  if (currency === 'USD') {
    return { ssdcWei: parseUnits(String(amount), 18), rate: null, updatedAt: null };
  }
  const fx = getFxContract();
  if (!fx) throw new Error('FxOracle not deployed; non-USD payouts unavailable');
  const pair = keccak256(toUtf8Bytes(`${currency}/ssUSD`));
  const fresh = await fx.isFresh(pair);
  if (!fresh) throw new Error(`FX quote stale or unknown for ${currency}/ssUSD`);
  const amountIn = parseUnits(String(amount), 18);
  const [amountOut, rate, updatedAt] = await fx.convert(pair, amountIn);
  return { ssdcWei: amountOut, rate, updatedAt };
}

// In-memory replay protection. In production this is a database keyed on
// (seller, nonce) with appropriate retention.
const usedNonces = new Map();   // seller (lower) → Set<nonce>

function safePathPart(value, field) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_.:-]{1,160}$/.test(value)) {
    throw new Error(`invalid ${field}`);
  }
  return value.replace(/[^A-Za-z0-9_.:-]/g, '_');
}

function nonceFileFor(seller, nonce, dir = NONCE_DIR) {
  const sellerPart = safePathPart(getAddress(String(seller).toLowerCase()).toLowerCase(), 'seller');
  const noncePart = safePathPart(String(nonce), 'nonce');
  return resolve(dir, sellerPart, `${noncePart}.json`);
}

function readJsonFile(path) {
  try {
    return JSON.parse(fs.readFileSync(path, 'utf-8'));
  } catch {
    return null;
  }
}

function writeJsonAtomic(path, data) {
  fs.mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.${Date.now()}.${crypto.randomBytes(4).toString('hex')}.tmp`;
  try {
    fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
    fs.renameSync(tmp, path);
  } catch (err) {
    fs.rmSync(tmp, { force: true });
    throw err;
  }
}

export function reservePayoutNonce(seller, nonce, dir = NONCE_DIR) {
  const file = nonceFileFor(seller, nonce, dir);
  fs.mkdirSync(dirname(file), { recursive: true });
  let fd;
  try {
    fd = fs.openSync(file, 'wx');
    fs.writeFileSync(fd, JSON.stringify({
      seller: getAddress(String(seller).toLowerCase()),
      nonce,
      status: 'processing',
      reservedAt: new Date().toISOString(),
    }, null, 2));
    return { reserved: true, file };
  } catch (err) {
    if (err.code === 'EEXIST') {
      return { reserved: false, file, status: readJsonFile(file)?.status || 'unknown' };
    }
    throw err;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

export function finalizePayoutNonce(seller, nonce, result, dir = NONCE_DIR) {
  const file = nonceFileFor(seller, nonce, dir);
  writeJsonAtomic(file, {
    seller: getAddress(String(seller).toLowerCase()),
    nonce,
    status: 'processed',
    processedAt: new Date().toISOString(),
    pullTx: result?.pull_tx,
    pullBlock: result?.pull_block,
    amountSsdcUnits: result?.pull_amount_ssdc_units,
  });
}

export function failPayoutNonce(seller, nonce, err, dir = NONCE_DIR) {
  const file = nonceFileFor(seller, nonce, dir);
  writeJsonAtomic(file, {
    seller: getAddress(String(seller).toLowerCase()),
    nonce,
    status: 'failed',
    failedAt: new Date().toISOString(),
    error: err?.message || String(err),
  });
}

// ─── Compose the canonical payout-request message ────────────────────────
// Seller signs this exact string. Bridge re-derives + verifies. Any change
// to amount, bank, nonce, or chain breaks the signature.
export function payoutMessage({ seller, amountUsd, bankLast4, nonce, issuedAt, chainId, outputCurrency = 'USD' }) {
  // Only checksum if it's a real-shape address; allow placeholders for /health.
  const sellerStr = /^0x[0-9a-fA-F]{40}$/.test(seller)
    ? getAddress(seller.toLowerCase())
    : seller;
  // `amountUsd` is the amount in `outputCurrency`. Field name kept for
  // backwards-compat with existing callers; semantically it's "amount in
  // seller's chosen payout currency". For USD the formatted line is
  // `amount:    $200.00 USD` — byte-identical to v1, so old signatures
  // still verify.
  return [
    'StateSet SSDC payout request v1',
    `seller:    ${sellerStr}`,
    `amount:    ${formatAmountForMessage(amountUsd, outputCurrency)} ${outputCurrency}`,
    `bank:      ****${bankLast4}`,
    `nonce:     ${nonce}`,
    `issuedAt:  ${issuedAt}`,
    `chainId:   ${chainId}`,
  ].join('\n');
}

// ─── Mock Stripe Treasury OutboundPayment shape ──────────────────────────
// https://stripe.com/docs/api/treasury/outbound_payments — same field names
// + types so a downstream consumer doesn't care that this isn't yet real.
function mockOutboundPayment({ seller, amountUsd, bankLast4, txHash, outputCurrency = 'USD' }) {
  const id = `obp_${crypto.randomBytes(12).toString('hex')}`;
  const created = Math.floor(Date.now() / 1000);
  const c = SUPPORTED_OUTPUT_CURRENCIES[outputCurrency];
  if (!c) throw new Error(`unsupported currency ${outputCurrency}`);
  return {
    object: 'treasury.outbound_payment',
    id,
    amount: Math.round(Number(amountUsd) * c.minorUnits),  // Stripe minor units; JPY/KRW are zero-decimal
    currency: c.isoLower,
    status: 'processing',  // → `posted` once ACH lands (T+1 in production)
    created,
    expected_arrival_date: created + 24 * 3600, // T+1
    destination_payment_method_details: {
      type: 'us_bank_account',
      us_bank_account: {
        last4: bankLast4,
      },
    },
    metadata: {
      stateset_source: 'ssdc-burn-bridge',
      stateset_seller_wallet: seller,
      stateset_pull_tx: txHash,
    },
    description: `StateSet SSDC payout for ${seller}`,
  };
}

// ─── Pure verification (chain-free; testable) ────────────────────────────
// Performs every check that doesn't require chain access: field shapes,
// amount bounds, bankLast4 format, replay (against provided nonce store),
// freshness, signature recovery. Returns { sellerChecked, message } on
// success; throws otherwise.
//
// `opts` lets tests inject:
//   - chainId      (default: REQUEST_TTL_SECS, etc. read from module consts)
//   - nonceStore   (default: module-level usedNonces)
//   - now          (default: Date.now()/1000)
//   - ttl          (default: REQUEST_TTL_SECS)
//   - minAmount/maxAmount  (default: MIN_PAYOUT_USD / MAX_PAYOUT_USD)
export function verifyPayoutRequest(body, opts = {}) {
  const {
    chainId,
    nonceStore = usedNonces,
    now = Date.now() / 1000,
    ttl = REQUEST_TTL_SECS,
    minAmount = MIN_PAYOUT_USD,
    maxAmount = MAX_PAYOUT_USD,
  } = opts;
  if (chainId === undefined) throw new Error('chainId is required');

  const { seller, amountUsd, bankLast4, nonce, issuedAt, signature, outputCurrency = 'USD' } = body;
  if (!seller || !amountUsd || !bankLast4 || !nonce || !issuedAt || !signature) {
    throw new Error('missing field — seller, amountUsd, bankLast4, nonce, issuedAt, signature required');
  }
  if (!SUPPORTED_OUTPUT_CURRENCIES[outputCurrency]) {
    throw new Error(`unsupported outputCurrency ${outputCurrency} (supported: ${Object.keys(SUPPORTED_OUTPUT_CURRENCIES).join(', ')})`);
  }
  if (amountUsd < minAmount || amountUsd > maxAmount) {
    // Bounds remain in the *signed amount's currency*. They're sanity bounds,
    // not policy — fine-grained per-currency limits should live elsewhere.
    throw new Error(`amount must be between ${minAmount} and ${maxAmount}`);
  }
  if (!/^\d{4}$/.test(String(bankLast4))) {
    throw new Error('bankLast4 must be 4 digits');
  }
  const sellerChecked = getAddress(String(seller).toLowerCase());

  // Replay protection — nonce must not have been used by this seller before.
  const seenForSeller = nonceStore.get(sellerChecked.toLowerCase()) || new Set();
  if (seenForSeller.has(nonce)) throw new Error('nonce already used');

  // Freshness window — both ways, so a forged-future timestamp can't bypass.
  const ageSec = now - Number(issuedAt);
  if (ageSec > ttl) throw new Error(`request older than ${ttl}s (${Math.round(ageSec)}s)`);
  if (ageSec < -60) throw new Error('issuedAt is in the future');

  // Recover signer from the canonical message — message binds amount, bank,
  // nonce, issuedAt, AND chainId, so cross-chain replay is also blocked.
  const message = payoutMessage({
    seller: sellerChecked, amountUsd, bankLast4, nonce, issuedAt, chainId, outputCurrency,
  });
  const recovered = verifyMessage(message, signature);
  if (recovered.toLowerCase() !== sellerChecked.toLowerCase()) {
    throw new Error(`signature does not recover to seller (got ${recovered})`);
  }
  return { sellerChecked, message, outputCurrency };
}

// ─── Handle a payout request ─────────────────────────────────────────────
async function handlePayout(body) {
  const network = await provider.getNetwork();
  const { sellerChecked, outputCurrency } = verifyPayoutRequest(body, { chainId: Number(network.chainId) });
  const { amountUsd, nonce, bankLast4 } = body;

  const reservation = reservePayoutNonce(sellerChecked, nonce);
  if (!reservation.reserved) throw new Error('nonce already used');

  try {
    // Convert seller's foreign-amount → SSDC via the on-chain FxOracle. USD
    // bypasses the oracle (1:1). The auditor can replay this conversion off
    // the FX quote logged at `updatedAt`.
    const { ssdcWei: amountUnits, rate, updatedAt } = await resolveSsdcAmount(amountUsd, outputCurrency);

    // Check balance + allowance
    const ssdc = getSsdcContract();
    const balance = await ssdc.balanceOf(sellerChecked);
    if (balance < amountUnits) {
      throw new Error(`insufficient SSDC balance: have ${formatUnits(balance, 18)}, need ${formatUnits(amountUnits, 18)}`);
    }
    const allowance = await ssdc.allowance(sellerChecked, bridge.address);
    if (allowance < amountUnits) {
      throw new Error(
        `insufficient SSDC allowance: have ${formatUnits(allowance, 18)}, need ${formatUnits(amountUnits, 18)}. ` +
        `Seller must call ssdc.approve(${bridge.address}, ${amountUnits}) first.`,
      );
    }

    // Pull SSDC into the bridge treasury (would be burned on settlement)
    const tx = await ssdc.transferFrom(sellerChecked, bridge.address, amountUnits, { gasLimit: 200_000n });
    const rcpt = await tx.wait();

    // Record nonce as used in-process too; the durable file blocks restarts.
    const seen = usedNonces.get(sellerChecked.toLowerCase()) || new Set();
    seen.add(nonce);
    usedNonces.set(sellerChecked.toLowerCase(), seen);

    const result = {
      pull_tx: rcpt.hash,
      pull_block: rcpt.blockNumber,
      pull_amount_ssdc_units: amountUnits.toString(),
      pull_amount_ssdc: formatUnits(amountUnits, 18),
      bridge_treasury: bridge.address,
      fx: outputCurrency === 'USD' ? null : {
        pair: `${outputCurrency}/ssUSD`,
        rate: rate?.toString(),
        quoteUpdatedAt: updatedAt ? Number(updatedAt) : null,
      },
      payout: mockOutboundPayment({
        seller: sellerChecked, amountUsd, bankLast4, txHash: rcpt.hash, outputCurrency,
      }),
    };
    finalizePayoutNonce(sellerChecked, nonce, result);
    return result;
  } catch (err) {
    failPayoutNonce(sellerChecked, nonce, err);
    throw err;
  }
}

// ─── HTTP server ─────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const send = (status, body) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(body));
  };

  if (req.method === 'GET' && req.url === '/health') {
    const a = loadAddresses();
    return send(200, {
      ok: true,
      ssdc: a.ssdcProxy,
      fxOracle: a.fxOracleAddr || null,
      bridge_treasury: bridge.address,
      supported_currencies: Object.keys(SUPPORTED_OUTPUT_CURRENCIES),
      message_template: payoutMessage({
        seller: '0x…', amountUsd: 0, bankLast4: '0000', nonce: 'YOUR_NONCE', issuedAt: 0, chainId: 0,
      }),
      message_template_gbp: payoutMessage({
        seller: '0x…', amountUsd: 0, bankLast4: '0000', nonce: 'YOUR_NONCE', issuedAt: 0, chainId: 0, outputCurrency: 'GBP',
      }),
    });
  }

  if (req.method !== 'POST' || req.url !== '/payout') {
    return send(404, { error: 'POST /payout or GET /health' });
  }

  let raw = '';
  req.setEncoding('utf-8');
  req.on('data', (c) => { raw += c; });
  req.on('end', async () => {
    try {
      const body = JSON.parse(raw);
      console.log(`[${new Date().toISOString()}] payout request from ${body.seller} for $${body.amountUsd}`);
      const result = await handlePayout(body);
      console.log(`  ✓ pulled SSDC tx ${result.pull_tx.slice(0, 16)}…  payout ${result.payout.id}`);
      send(200, result);
    } catch (err) {
      console.error(`  ✗ ${err.message}`);
      send(400, { error: err.message });
    }
  });
});

// Only start the listener when run as a script — tests can `import` the
// pure functions without spawning the HTTP server.
const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  const a = loadAddresses();
  server.listen(PORT, () => {
    console.log(`\nSSDC → Stripe Treasury bridge listening on :${PORT}`);
    console.log(`  RPC                ${RPC_URL}`);
    console.log(`  SSDC               ${a.ssdcProxy}`);
    console.log(`  bridge treasury    ${bridge.address}`);
    console.log(`\n  POST /payout       signed withdrawal request → SSDC pulled, payout queued`);
    console.log(`  GET  /health       bridge state + signing message template\n`);
  });
}
