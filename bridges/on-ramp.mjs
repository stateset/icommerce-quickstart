#!/usr/bin/env node
/**
 * Stripe → SSDC bridge — fiat on-ramp to on-chain commerce.
 *
 * A minimal HTTP server that:
 *   1. Receives Stripe-shaped webhook events at POST /webhook
 *   2. Verifies the `Stripe-Signature` header (HMAC SHA256, same as production)
 *   3. On `checkout.session.completed`, mints SSDC into the buyer's wallet
 *      (1:1 with the USD amount, treasury-vault path)
 *   4. Optionally locks into OrderEscrow if the event metadata names a seller
 *
 * The mock-stripe-event.mjs companion script signs and posts events with the
 * exact same algorithm Stripe uses, so the bridge logic is production-shaped.
 *
 * Why this matters: every commerce-rail demo so far ran on funds the demo
 * minted to itself. This bridge is the literal answer to "where does the
 * money come from." Set up `STRIPE_WEBHOOK_SECRET`, point Stripe at this
 * endpoint, swap localhost:8545 for a real RPC, and the same code path
 * accepts real card payments and produces SSDC-denominated escrow orders.
 *
 * Run:
 *   STRIPE_WEBHOOK_SECRET=whsec_test123 node bridge/stripe-to-ssdc.mjs
 */

import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import {
  JsonRpcProvider, Wallet, Contract,
  parseUnits, formatUnits, getAddress,
  keccak256, toUtf8Bytes,
} from 'ethers';

export function readPositiveIntegerEnv(name, fallback, source = process.env, options = {}) {
  const raw = source[name];
  if (raw === undefined || raw === '') return fallback;
  if (!/^\d+$/.test(String(raw))) {
    throw new Error(`${name} must be a positive integer`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  if (options.max !== undefined && value > options.max) {
    throw new Error(`${name} must be <= ${options.max}`);
  }
  return value;
}

const PORT = readPositiveIntegerEnv('PORT', 4242, process.env, { max: 65535 });
const RPC_URL = process.env.RPC_URL || 'http://localhost:8545';
const SECRET = process.env.STRIPE_WEBHOOK_SECRET || 'whsec_test_local_only';
const SIGNING_TOLERANCE = 5 * 60; // seconds — same as Stripe's default
const MAX_WEBHOOK_BYTES = readPositiveIntegerEnv('MAX_WEBHOOK_BYTES', 1024 * 1024);

// ─── Locate the deployed contracts ────────────────────────────────────────
// Read from the repo's own broadcast log produced by `forge script DeployLocal`.
// Override with BROADCAST_LOG=/abs/path/to/run-latest.json when running against
// a different deploy (e.g. testnet, fork, or a sibling monorepo checkout).
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const __here = dirname(fileURLToPath(import.meta.url));
const broadcastLog = process.env.BROADCAST_LOG
  || resolve(__here, '../contracts/broadcast/DeployLocal.s.sol/84532001/run-latest.json');
const IDEMPOTENCY_DIR = process.env.STRIPE_IDEMPOTENCY_DIR
  || resolve(__here, '../stack/.run/stripe-events');

// LAZY: tests can import verifyStripeSignature without a deployed chain.
let _addrs = null;
function loadAddresses() {
  if (_addrs) return _addrs;
  const log = JSON.parse(fs.readFileSync(broadcastLog, 'utf-8'));
  const proxies = log.transactions.filter((t) => t.contractName === 'ERC1967Proxy');
  _addrs = {
    escrowAddr:   log.transactions.find((t) => t.contractName === 'OrderEscrow').contractAddress,
    ssdcProxy:    proxies[3].contractAddress,
    fxOracleAddr: log.transactions.find((t) => t.contractName === 'FxOracle').contractAddress,
  };
  return _addrs;
}

const SUPPORTED_CURRENCIES = ['USD', 'EUR', 'GBP', 'JPY', 'MXN'];
// Stripe `amount_total` is in the currency's smallest unit. Zero-decimal
// currencies (JPY, KRW, …) report the integer; everything else is 1/100.
const ZERO_DECIMAL_CURRENCIES = new Set([
  'JPY', 'KRW', 'BIF', 'CLP', 'DJF', 'GNF', 'PYG', 'RWF', 'UGX', 'VND', 'VUV', 'XAF', 'XOF', 'XPF',
]);
export function stripeMinorToDecimalString(minor, currency) {
  if (!Number.isSafeInteger(minor) || minor <= 0) {
    throw new Error('checkout.session amount_total must be a positive integer in minor units');
  }
  if (ZERO_DECIMAL_CURRENCIES.has(currency)) return String(minor);

  const raw = String(minor).padStart(3, '0');
  return `${raw.slice(0, -2)}.${raw.slice(-2)}`;
}

export function stripeMinorToHuman(minor, currency) {
  return Number(stripeMinorToDecimalString(minor, currency));
}

// Treasury (deployer) — only address that can mintShares on SSDC.
// In production this is a hot wallet held by the bridge operator with a
// rate limit + multi-sig escape hatch. Demo uses the deterministic anvil[0].
const TREASURY_KEY = process.env.TREASURY_KEY
  || '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';

const provider = new JsonRpcProvider(RPC_URL);
const treasury = new Wallet(TREASURY_KEY, provider);

const SSDC_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function decimals() pure returns (uint8)',
  'function mintShares(address to, uint256 shares)',
];
const FX_ABI = [
  'function isFresh(bytes32) view returns (bool)',
  'function convert(bytes32 pair, uint256 amountIn) view returns (uint256 amountOut, uint256 rate, uint64 updatedAt)',
];
let _ssdc, _fx;
function getSsdc() {
  if (_ssdc) return _ssdc;
  _ssdc = new Contract(loadAddresses().ssdcProxy, SSDC_ABI, treasury);
  return _ssdc;
}
function getFx() {
  if (_fx) return _fx;
  _fx = new Contract(loadAddresses().fxOracleAddr, FX_ABI, provider);
  return _fx;
}

// ─── Stripe-style webhook signature verification ─────────────────────────
// Reproduces github.com/stripe/stripe-node/.../Webhook.constructEvent so the
// bridge accepts real Stripe events with no library on the server side.
export function verifyStripeSignature(rawBody, signatureHeader, secret, options = {}) {
  // options.tolerance overrides SIGNING_TOLERANCE; options.now (in seconds)
  // overrides Date.now() — both used by the test suite. Production callers
  // pass neither.
  const tolerance = options.tolerance ?? SIGNING_TOLERANCE;
  const nowSec = options.now ?? (Date.now() / 1000);
  return _verifyStripeSignatureImpl(rawBody, signatureHeader, secret, tolerance, nowSec);
}

function _verifyStripeSignatureImpl(rawBody, signatureHeader, secret, tolerance, nowSec) {
  if (!signatureHeader) throw new Error('missing Stripe-Signature header');
  let t = null;
  const signatures = [];
  for (const kv of signatureHeader.split(',')) {
    const idx = kv.indexOf('=');
    if (idx === -1) continue;
    const key = kv.slice(0, idx).trim();
    const value = kv.slice(idx + 1).trim();
    if (key === 't') t = value;
    if (key === 'v1') signatures.push(value);
  }
  if (!t || signatures.length === 0) throw new Error('malformed signature header');
  const timestamp = Number(t);
  if (!Number.isFinite(timestamp)) throw new Error('malformed signature timestamp');

  if (Math.abs(nowSec - timestamp) > tolerance) {
    throw new Error('signature timestamp outside tolerance');
  }

  const signedPayload = `${t}.${rawBody}`;
  const expected = crypto.createHmac('sha256', secret).update(signedPayload).digest('hex');

  const expectedBuf = Buffer.from(expected, 'hex');
  const matched = signatures.some((sig) => {
    if (!/^[0-9a-fA-F]+$/.test(sig) || sig.length !== expected.length) return false;
    const provided = Buffer.from(sig, 'hex');
    return provided.length === expectedBuf.length && crypto.timingSafeEqual(provided, expectedBuf);
  });
  if (!matched) {
    throw new Error('signature mismatch');
  }
  return { timestamp, verified: true };
}

function safeId(id, field) {
  if (typeof id !== 'string' || !/^[A-Za-z0-9_.:-]{3,128}$/.test(id)) {
    throw new Error(`invalid ${field}`);
  }
  return id.replace(/[^A-Za-z0-9_.:-]/g, '_');
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

export function reserveStripeEvent(eventId, dir = IDEMPOTENCY_DIR) {
  const file = resolve(dir, `${safeId(eventId, 'event.id')}.json`);
  fs.mkdirSync(dir, { recursive: true });
  let fd;
  try {
    fd = fs.openSync(file, 'wx');
    fs.writeFileSync(fd, JSON.stringify({
      eventId,
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

export function finalizeStripeEvent(eventId, result, dir = IDEMPOTENCY_DIR) {
  const file = resolve(dir, `${safeId(eventId, 'event.id')}.json`);
  writeJsonAtomic(file, {
    eventId,
    status: 'processed',
    processedAt: new Date().toISOString(),
    txHash: result?.txHash,
    block: result?.block,
    buyer: result?.buyer,
    amountSsUsd: result?.amountSsUsd,
  });
}

export function failStripeEvent(eventId, err, dir = IDEMPOTENCY_DIR) {
  const file = resolve(dir, `${safeId(eventId, 'event.id')}.json`);
  writeJsonAtomic(file, {
    eventId,
    status: 'failed',
    failedAt: new Date().toISOString(),
    error: err?.message || String(err),
  });
}

// ─── Event handler: mint SSDC when a checkout completes ──────────────────
async function handleEvent(event) {
  if (event.type !== 'checkout.session.completed') {
    return { handled: false, reason: `ignored event ${event.type}` };
  }
  const sess = event.data?.object;
  if (!sess) throw new Error('event has no data.object');
  if (sess.payment_status !== 'paid') {
    throw new Error(`checkout.session payment_status must be paid (got ${sess.payment_status || 'missing'})`);
  }

  // The buyer's on-chain wallet is carried in metadata. In production this is
  // populated by the merchant's checkout-session-create call — Stripe stores
  // it server-side and replays it back in the webhook.
  const wallet = sess.metadata?.buyer_wallet;
  if (!wallet) throw new Error('checkout.session has no metadata.buyer_wallet');
  const checksumAddr = getAddress(wallet.toLowerCase());

  const currency = (sess.currency || 'usd').toUpperCase();
  if (!SUPPORTED_CURRENCIES.includes(currency)) {
    throw new Error(`unsupported currency ${currency} (supported: ${SUPPORTED_CURRENCIES.join(', ')})`);
  }
  const amountDecimal = stripeMinorToDecimalString(sess.amount_total, currency);
  const amountForeign = Number(amountDecimal);

  // Compute SSDC to mint. USD is 1:1 (NAV starts at $1.00). Non-USD goes
  // through the on-chain FxOracle so an auditor can verify the rate that
  // was applied at mint time.
  let sharesToMint, fxRate = null, fxUpdatedAt = null, amountSsUsd;
  if (currency === 'USD') {
    amountSsUsd = amountForeign;
    sharesToMint = parseUnits(amountDecimal, 18);
  } else {
    const pairId = keccak256(toUtf8Bytes(`${currency}/ssUSD`));
    const fxOracle = getFx();
    const fresh = await fxOracle.isFresh(pairId);
    if (!fresh) throw new Error(`FX quote stale or unknown for ${currency}/ssUSD`);
    const amountIn = parseUnits(amountDecimal, 18);
    const [amountOut18, rate, updatedAt] = await fxOracle.convert(pairId, amountIn);
    sharesToMint = amountOut18; // SSDC is 18dp — convert output already 1e18-scaled
    amountSsUsd = Number(formatUnits(amountOut18, 18));
    fxRate = formatUnits(rate, 18);
    fxUpdatedAt = Number(updatedAt);
  }

  const minLog = currency === 'USD'
    ? `${amountSsUsd.toFixed(2)} SSDC`
    : `${amountForeign.toLocaleString()} ${currency} → ${amountSsUsd.toFixed(2)} SSDC (rate ${fxRate})`;
  console.log(`  → minting ${minLog} to ${checksumAddr}…`);
  const ssdc = getSsdc();
  const tx = await ssdc.mintShares(checksumAddr, sharesToMint, { gasLimit: 200_000n });
  const rcpt = await tx.wait();
  const balance = await ssdc.balanceOf(checksumAddr);

  return {
    handled: true,
    sessionId: sess.id,
    buyer: checksumAddr,
    currency,
    amountForeign,
    amountSsUsd,
    fxRate,
    fxUpdatedAt,
    txHash: rcpt.hash,
    block: rcpt.blockNumber,
    walletBalance: formatUnits(balance, 18),
  };
}

// ─── HTTP server ─────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    const a = loadAddresses();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, ssdc: a.ssdcProxy, escrow: a.escrowAddr, treasury: treasury.address }));
    return;
  }

  if (req.method !== 'POST' || req.url !== '/webhook') {
    res.writeHead(404).end();
    return;
  }

  let raw = '';
  let rawBytes = 0;
  let tooLarge = false;
  req.setEncoding('utf-8');
  req.on('data', (chunk) => {
    if (tooLarge) return;
    rawBytes += Buffer.byteLength(chunk, 'utf-8');
    if (rawBytes > MAX_WEBHOOK_BYTES) {
      tooLarge = true;
      raw = '';
      return;
    }
    raw += chunk;
  });
  req.on('end', async () => {
    if (tooLarge) {
      res.writeHead(413, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: `request body exceeds ${MAX_WEBHOOK_BYTES} bytes` }));
      return;
    }
    let reserved = null;
    let reservedEventId = null;
    try {
      verifyStripeSignature(raw, req.headers['stripe-signature'], SECRET);
      const event = JSON.parse(raw);
      console.log(`[${new Date().toISOString()}] received ${event.type}`);
      if (event.type === 'checkout.session.completed') {
        reserved = reserveStripeEvent(event.id);
        reservedEventId = event.id;
        if (!reserved.reserved) {
          console.log(`  ↺ duplicate event ${event.id}; reservation status=${reserved.status}`);
          if (reserved.status === 'processed') {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ received: true, duplicate: true }));
          } else {
            const status = reserved.status === 'processing' ? 409 : 500;
            res.writeHead(status, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
              error: `event ${event.id} is already ${reserved.status || 'reserved'}`,
            }));
          }
          return;
        }
      }
      const result = await handleEvent(event);
      if (reserved?.reserved) finalizeStripeEvent(event.id, result);
      console.log(`  ✓`, JSON.stringify(result));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ received: true, ...result }));
    } catch (err) {
      if (reserved?.reserved && reservedEventId) failStripeEvent(reservedEventId, err);
      console.error(`  ✗ ${err.message}`);
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: err.message }));
    }
  });
});

// Only start the HTTP server when run as a script, so tests can `import`
// verifyStripeSignature without spawning a listener.
const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  const a = loadAddresses();
  server.listen(PORT, () => {
    console.log(`\nStripe → SSDC bridge listening on :${PORT}`);
    console.log(`  webhook secret  ${SECRET.slice(0, 10)}…`);
    console.log(`  RPC             ${RPC_URL}`);
    console.log(`  SSDC            ${a.ssdcProxy}`);
    console.log(`  treasury        ${treasury.address}`);
    console.log(`\n  POST /webhook   accepts Stripe-Signature-headers`);
    console.log(`  GET  /health    bridge state\n`);
  });
}
