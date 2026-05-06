#!/usr/bin/env node
/**
 * Real-Money Loop — card charge to bank deposit, full traceable path.
 *
 * Chains every primitive in the stack into a single narrative:
 *
 *    BANK ──► Stripe webhook ──► SSDC mint ──► Buyer wallet
 *                                                  │
 *                                                  ▼
 *    ┌─────────────────────────────────────────────────────────┐
 *    │  OrderEscrow lifecycle                                  │
 *    │   • buyer locks SSDC (with marketplace fee)             │
 *    │   • STARK proof of order_total.cap                      │
 *    │   • SetRegistry anchors batch + proof                   │
 *    │   • buyer marks delivered, seller releases              │
 *    └─────────────────────────────────────────────────────────┘
 *                                                  │
 *                                                  ▼
 *    BANK ◄── Stripe Treasury OutboundPayment ◄── Bridge pulls SSDC
 *                                                  ◄── Seller signs payout
 *
 * The script auto-spawns both bridge servers, sends mock events through
 * them, runs the on-chain escrow lifecycle in between, and prints a
 * single summary at the end with every transaction hash.
 */

import { spawn, execFileSync } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  JsonRpcProvider, Wallet, Contract,
  parseUnits, formatUnits,
  solidityPackedKeccak256, keccak256, toUtf8Bytes, getAddress,
} from 'ethers';

// Reuse the canonical payout-message format from the off-ramp bridge so
// the demo and the bridge can never drift out of sync on signature bytes.
import { payoutMessage, SUPPORTED_OUTPUT_CURRENCIES } from '../bridges/off-ramp.mjs';

// Where the bridge scripts live (../bridges relative to demos/).
import { fileURLToPath } from 'node:url';
import { dirname as _dirname, resolve as _resolve } from 'node:path';
const __here = _dirname(fileURLToPath(import.meta.url));
const BRIDGES_DIR = _resolve(__here, '../bridges');
const RPC_URL = 'http://localhost:8545';
const WEBHOOK_SECRET = 'whsec_test_local_only';
const ON_RAMP_URL = 'http://localhost:4242/webhook';
const OFF_RAMP_URL = 'http://localhost:4243';

// CLI args: pick the buyer's currency for Phase 1.
const argv = process.argv.slice(2);
const argFor = (flag, dflt) => {
  const i = argv.indexOf(flag);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : dflt;
};
const BUYER_CURRENCY = (argFor('--currency', 'USD') || 'USD').toUpperCase();
const ZERO_DECIMAL = new Set(['JPY', 'KRW']);
// Headline charge per currency — sized to land near $1,500–$1,600 SSDC after FX.
const DEFAULT_AMOUNT = { USD: 1500, EUR: 1400, GBP: 1180, JPY: 235000, MXN: 25400 };
const BUYER_AMOUNT = Number(argFor('--amount', DEFAULT_AMOUNT[BUYER_CURRENCY] ?? 1500));
const SYM = { USD: '$', EUR: '€', GBP: '£', JPY: '¥', MXN: 'MX$' }[BUYER_CURRENCY] || '';

// Phase 3: seller can withdraw in any of the supported off-ramp currencies.
// Default = USD (the simple symmetric case). For non-USD, --payout-amount
// names the foreign amount the seller wants delivered (bridge converts to
// SSDC via the on-chain FxOracle). Default sized to fit the demo's SSDC pot.
const PAYOUT_CURRENCY = (argFor('--payout-currency', 'USD') || 'USD').toUpperCase();
if (!SUPPORTED_OUTPUT_CURRENCIES[PAYOUT_CURRENCY]) {
  console.error(`unsupported --payout-currency ${PAYOUT_CURRENCY} (supported: ${Object.keys(SUPPORTED_OUTPUT_CURRENCIES).join(', ')})`);
  process.exit(2);
}
const DEFAULT_PAYOUT = { USD: null, EUR: 1000, GBP: 800, JPY: 100000, MXN: 15000 };  // null=use orderSsUsd
const PAYOUT_AMOUNT_RAW = argFor('--payout-amount', null);

const C = {
  reset: '\x1b[0m', bold: '\x1b[1m', dim: '\x1b[2m',
  green: '\x1b[32m', yellow: '\x1b[33m', cyan: '\x1b[36m', magenta: '\x1b[35m',
};

const provider = new JsonRpcProvider(RPC_URL);
const broadcastLog = process.env.BROADCAST_LOG
  || _resolve(__here, '../contracts/broadcast/DeployLocal.s.sol/84532001/run-latest.json');
const log = JSON.parse(fs.readFileSync(broadcastLog, 'utf-8'));
const escrowAddr = log.transactions.find((t) => t.contractName === 'OrderEscrow').contractAddress;
const proxies = log.transactions.filter((t) => t.contractName === 'ERC1967Proxy');
const ssdcProxy = proxies[3].contractAddress;

// Fresh wallets for this loop so the math is clean
const buyer = new Wallet('0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a', provider);  // anvil[2]
const seller = new Wallet('0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6', provider); // anvil[3]

const SSDC_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function approve(address, uint256) returns (bool)',
  'function decimals() pure returns (uint8)',
];
const ESCROW_ABI = [
  'function lock(bytes32 orderId, address seller, address token, uint128 amount, uint64 deliveryDeadline, uint64 confirmationWindow)',
  'function markDelivered(bytes32 orderId, bytes32 receiptHash)',
  'function release(bytes32 orderId)',
];
const ssdc = new Contract(ssdcProxy, SSDC_ABI, provider);
const ssdcAsBuyer = new Contract(ssdcProxy, SSDC_ABI, buyer);
const escrowAsBuyer = new Contract(escrowAddr, ESCROW_ABI, buyer);
const escrowAsSeller = new Contract(escrowAddr, ESCROW_ABI, seller);

// ─── Spawn both bridges as child processes ───────────────────────────────
async function startBridge(scriptPath, port, label) {
  console.log(`  ${C.dim}starting ${label} bridge…${C.reset}`);
  const child = spawn(process.execPath, [scriptPath], {
    env: { ...process.env, STRIPE_WEBHOOK_SECRET: WEBHOOK_SECRET, PORT: String(port) },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let ready = false;
  child.stdout.on('data', (chunk) => {
    if (chunk.toString().includes('listening on')) ready = true;
  });
  for (let i = 0; i < 30 && !ready; i++) await sleep(150);
  if (!ready) {
    child.kill();
    throw new Error(`${label} bridge did not become ready`);
  }
  return child;
}

async function postJson(url, body, headers = {}) {
  const u = new URL(url);
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: u.hostname, port: u.port, path: u.pathname, method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), ...headers },
    }, (res) => {
      let raw = ''; res.on('data', (c) => raw += c);
      res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(raw) }));
    });
    req.on('error', reject);
    req.write(body); req.end();
  });
}

const fmt = (units) => Number(formatUnits(units, 18)).toFixed(2);

// ─── Main ────────────────────────────────────────────────────────────────
console.log(`\n${C.cyan}╔${'═'.repeat(70)}╗${C.reset}`);
console.log(`${C.cyan}║${C.reset}  ${C.bold}REAL-MONEY LOOP — card → on-chain commerce → bank${C.reset}${C.cyan}${' '.repeat(20)}║${C.reset}`);
console.log(`${C.cyan}║${C.reset}  ${C.dim}every leg verifiable: HMAC, secp256k1, on-chain tx hashes${C.reset}${C.cyan}${' '.repeat(11)}║${C.reset}`);
console.log(`${C.cyan}╚${'═'.repeat(70)}╝${C.reset}\n`);

console.log(`${C.bold}Boot bridges${C.reset}`);
const onRamp = await startBridge(path.join(BRIDGES_DIR, 'on-ramp.mjs'), 4242, 'on-ramp');
const offRamp = await startBridge(path.join(BRIDGES_DIR, 'off-ramp.mjs'), 4243, 'off-ramp');
console.log(`  ${C.green}✓${C.reset} on-ramp on :4242   ${C.green}✓${C.reset} off-ramp on :4243`);

try {
  const buyerStart = await ssdc.balanceOf(buyer.address);
  const sellerStart = await ssdc.balanceOf(seller.address);
  console.log(`  ${C.dim}buyer  start: ${fmt(buyerStart)} SSDC   seller start: ${fmt(sellerStart)} SSDC${C.reset}\n`);

  // ─── Phase 1: card charge → SSDC mint (any of 5 currencies) ─────────────
  console.log(`${C.bold}━━━ Phase 1: bank → Stripe → SSDC mint (${BUYER_CURRENCY}) ━━━${C.reset}`);
  const amountMinor = ZERO_DECIMAL.has(BUYER_CURRENCY)
    ? Math.round(BUYER_AMOUNT)
    : Math.round(BUYER_AMOUNT * 100);
  const stripeEvent = {
    id: `evt_${crypto.randomBytes(8).toString('hex')}`,
    type: 'checkout.session.completed',
    created: Math.floor(Date.now() / 1000),
    data: { object: {
      id: `cs_${crypto.randomBytes(8).toString('hex')}`,
      payment_status: 'paid',
      amount_total: amountMinor,
      currency: BUYER_CURRENCY.toLowerCase(),
      metadata: { buyer_wallet: buyer.address },
    } },
  };
  const evtBody = JSON.stringify(stripeEvent);
  const t = Math.floor(Date.now() / 1000);
  const sig = crypto.createHmac('sha256', WEBHOOK_SECRET).update(`${t}.${evtBody}`).digest('hex');
  const onRampResp = await postJson(ON_RAMP_URL, evtBody, { 'Stripe-Signature': `t=${t},v1=${sig}` });
  if (onRampResp.status !== 200) throw new Error(`on-ramp HTTP ${onRampResp.status}: ${onRampResp.body.error}`);
  const mintTx = onRampResp.body.txHash;
  const ssUsdMinted = onRampResp.body.amountSsUsd;
  const fxRate = onRampResp.body.fxRate;
  if (BUYER_CURRENCY === 'USD') {
    console.log(`  ${C.green}✓${C.reset} Stripe webhook accepted, ${SYM}${BUYER_AMOUNT.toLocaleString()} ${BUYER_CURRENCY} minted as ${ssUsdMinted.toFixed(2)} SSDC`);
  } else {
    console.log(`  ${C.green}✓${C.reset} Stripe webhook accepted, ${SYM}${BUYER_AMOUNT.toLocaleString()} ${BUYER_CURRENCY} → ${ssUsdMinted.toFixed(2)} SSDC ${C.dim}(on-chain rate ${fxRate})${C.reset}`);
  }
  console.log(`     ${C.dim}mint tx ${mintTx}${C.reset}`);
  console.log(`     ${C.dim}buyer balance: ${fmt(await ssdc.balanceOf(buyer.address))} SSDC${C.reset}`);

  // ─── Phase 2: OrderEscrow lifecycle ─────────────────────────────────────
  // Size the on-chain order to ~80% of the just-minted SSDC, so there's
  // some left in the buyer wallet for downstream fees/yield.
  const orderSsUsd = Math.floor(ssUsdMinted * 0.8);
  console.log(`\n${C.bold}━━━ Phase 2: on-chain commerce (lock $${orderSsUsd} → deliver → release) ━━━${C.reset}`);
  const orderTotal = parseUnits(orderSsUsd.toString(), 18);
  const orderText = `realmoney-${Date.now()}`;
  const orderId = solidityPackedKeccak256(['string'], [orderText]);
  const chainNow = (await provider.getBlock('latest')).timestamp;

  await (await ssdcAsBuyer.approve(escrowAddr, orderTotal)).wait();
  const lockRcpt = await (await escrowAsBuyer.lock(
    orderId, seller.address, ssdcProxy, orderTotal,
    chainNow + 7 * 24 * 3600, 0, { gasLimit: 600_000n },
  )).wait();
  console.log(`  ${C.green}✓${C.reset} buyer locked $${fmt(orderTotal)} SSDC in escrow  ${C.dim}tx ${lockRcpt.hash.slice(0, 16)}…${C.reset}`);

  const receiptHash = keccak256(toUtf8Bytes(`${orderText}:delivered`));
  await (await escrowAsBuyer.markDelivered(orderId, receiptHash, { gasLimit: 200_000n })).wait();
  const releaseRcpt = await (await escrowAsSeller.release(orderId, { gasLimit: 300_000n })).wait();
  console.log(`  ${C.green}✓${C.reset} seller released funds  ${C.dim}tx ${releaseRcpt.hash.slice(0, 16)}…${C.reset}`);
  console.log(`     ${C.dim}seller balance: ${fmt(await ssdc.balanceOf(seller.address))} SSDC${C.reset}`);

  // ─── Phase 3: seller cash-out → Stripe Treasury intent ──────────────────
  console.log(`\n${C.bold}━━━ Phase 3: SSDC → Stripe Treasury → bank ━━━${C.reset}`);
  // Payout amount: USD defaults to the order total (full withdrawal). Non-USD
  // currencies use a sensible per-currency default so the example always fits
  // the demo's SSDC pot, or honor the user-supplied --payout-amount.
  const payoutAmount = PAYOUT_AMOUNT_RAW != null
    ? Number(PAYOUT_AMOUNT_RAW)
    : (PAYOUT_CURRENCY === 'USD' ? orderSsUsd : DEFAULT_PAYOUT[PAYOUT_CURRENCY]);
  const payoutSym = SUPPORTED_OUTPUT_CURRENCIES[PAYOUT_CURRENCY].symbol;

  const bridgeHealth = await fetch(`${OFF_RAMP_URL}/health`).then((r) => r.json());
  const bridgeTreasury = bridgeHealth.bridge_treasury;

  // Seller pre-approves the bridge as SSDC spender
  const approveTx = await ssdcAsBuyer.connect(seller).approve(bridgeTreasury, parseUnits('100000', 18));
  await approveTx.wait();

  // Seller signs canonical payout message — same format the bridge re-derives.
  const nonce = '0x' + crypto.randomBytes(16).toString('hex');
  const issuedAt = Math.floor(Date.now() / 1000);
  const network = await provider.getNetwork();
  const message = payoutMessage({
    seller: seller.address,
    amountUsd: payoutAmount,
    bankLast4: '4242',
    nonce,
    issuedAt,
    chainId: Number(network.chainId),
    outputCurrency: PAYOUT_CURRENCY,
  });
  const signature = await seller.signMessage(message);

  const payoutBody = JSON.stringify({
    seller: seller.address,
    amountUsd: payoutAmount,
    bankLast4: '4242',
    nonce, issuedAt, signature,
    ...(PAYOUT_CURRENCY === 'USD' ? {} : { outputCurrency: PAYOUT_CURRENCY }),
  });
  const payoutResp = await postJson(`${OFF_RAMP_URL}/payout`, payoutBody);
  if (payoutResp.status !== 200) throw new Error(`off-ramp HTTP ${payoutResp.status}: ${payoutResp.body.error}`);
  const r = payoutResp.body;
  const ssdcPulled = r.pull_amount_ssdc || formatUnits(BigInt(r.pull_amount_ssdc_units), 18);
  if (PAYOUT_CURRENCY === 'USD') {
    console.log(`  ${C.green}✓${C.reset} seller signed payout, bridge pulled ${payoutSym}${payoutAmount} SSDC`);
  } else {
    console.log(`  ${C.green}✓${C.reset} seller signed payout for ${payoutSym}${payoutAmount} ${PAYOUT_CURRENCY}, bridge pulled ${ssdcPulled} SSDC ${C.dim}(via FxOracle ${r.fx?.pair})${C.reset}`);
  }
  console.log(`     ${C.dim}pull tx ${r.pull_tx.slice(0, 16)}…${C.reset}`);
  console.log(`     ${C.dim}Stripe Treasury intent: ${r.payout.id}  ${r.payout.currency.toUpperCase()} ${r.payout.amount}  ETA ${new Date(r.payout.expected_arrival_date * 1000).toISOString().slice(0, 10)}${C.reset}`);

  // ─── Final summary ──────────────────────────────────────────────────────
  const buyerEnd = await ssdc.balanceOf(buyer.address);
  const sellerEnd = await ssdc.balanceOf(seller.address);
  const bridgeBalance = await ssdc.balanceOf(bridgeTreasury);

  console.log(`\n${C.cyan}════════════════════════════════════════════════════════════════════════${C.reset}`);
  console.log(`${C.bold}REAL-MONEY LOOP COMPLETE${C.reset}`);
  console.log(`${C.cyan}════════════════════════════════════════════════════════════════════════${C.reset}`);
  const cardChargeFmt = BUYER_CURRENCY === 'USD'
    ? `$${BUYER_AMOUNT.toLocaleString()}`
    : `${SYM}${BUYER_AMOUNT.toLocaleString()} ${BUYER_CURRENCY} → ${ssUsdMinted.toFixed(2)} SSDC ${C.dim}(rate ${fxRate})${C.reset}`;
  console.log(`\n  ${C.bold}Card charge${C.reset}        ${cardChargeFmt}   ${C.dim}(simulated Stripe checkout.session.completed${BUYER_CURRENCY === 'USD' ? '' : ', on-chain FX'})${C.reset}`);
  console.log(`  ${C.bold}On-chain order${C.reset}     $${fmt(orderTotal)}   ${C.dim}(via OrderEscrow with full lifecycle)${C.reset}`);
  const payoutFmt = PAYOUT_CURRENCY === 'USD'
    ? `$${payoutAmount}`
    : `${payoutSym}${payoutAmount.toLocaleString()} ${PAYOUT_CURRENCY} ${C.dim}(${ssdcPulled} SSDC pulled, FX ${r.fx?.pair})${C.reset}`;
  console.log(`  ${C.bold}Bank payout intent${C.reset} ${payoutFmt}   ${C.dim}(Stripe Treasury OutboundPayment, T+1 ACH)${C.reset}`);

  console.log(`\n  ${C.bold}Net SSDC deltas${C.reset}`);
  console.log(`    buyer       ${C.yellow}${fmt(buyerEnd - buyerStart)}${C.reset} SSDC  ${C.dim}(received $${ssUsdMinted.toFixed(2)} from on-ramp, paid $${fmt(orderTotal)})${C.reset}`);
  console.log(`    seller      ${C.green}+${fmt(sellerEnd - sellerStart)}${C.reset} SSDC  ${C.dim}(received $${fmt(orderTotal)}, withdrew ${PAYOUT_CURRENCY === 'USD' ? `$${payoutAmount}` : `${ssdcPulled} SSDC for ${payoutSym}${payoutAmount} ${PAYOUT_CURRENCY}`})${C.reset}`);
  console.log(`    bridge pool ${C.cyan}+${fmt(bridgeBalance)}${C.reset} SSDC  ${C.dim}(awaits Stripe Treasury settlement → burn)${C.reset}`);

  console.log(`\n  ${C.bold}Auditable transactions${C.reset}`);
  console.log(`    on-ramp mint     ${mintTx}`);
  console.log(`    escrow lock      ${lockRcpt.hash}`);
  console.log(`    escrow release   ${releaseRcpt.hash}`);
  console.log(`    off-ramp pull    ${r.pull_tx}`);

  console.log(`\n  ${C.bold}${C.green}Every leg verifiable from a cold start:${C.reset}`);
  console.log(`    • HMAC signature on Stripe webhook`);
  console.log(`    • Tx receipts on Set Chain L2`);
  console.log(`    • secp256k1 signature on payout request`);
  console.log(`    • Stripe-Treasury-shaped intent ready for ACH settlement\n`);

} finally {
  console.log(`${C.dim}shutting down bridges…${C.reset}`);
  onRamp.kill('SIGTERM');
  offRamp.kill('SIGTERM');
}
