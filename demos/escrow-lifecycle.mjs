#!/usr/bin/env node
/**
 * escrow-lifecycle.mjs — the simplest possible end-to-end commerce demo.
 *
 *   buyer wallet ──[lock]──► OrderEscrow ──[release]──► seller wallet
 *
 * Five state transitions, two participants, no sequencer, no STARK proofs,
 * no bridges. Just ethers + the deployed contracts. If this works, the
 * stack is healthy.
 *
 *   1. Buyer approves the escrow as an SSDC spender
 *   2. Buyer locks SSDC with seller + amount + delivery deadline
 *   3. Seller markDelivered (with a receipt hash)
 *   4. Buyer release  (or refund-after-deadline if delivery slips)
 *   5. Print final balances + tx hashes for auditing
 *
 * Prerequisites:
 *   - anvil running on RPC_URL (default http://localhost:8545)
 *   - contracts deployed via `forge script script/DeployLocal.s.sol --broadcast`
 *
 * Run:
 *   node demos/escrow-lifecycle.mjs
 *   ORDER_USD=500 node demos/escrow-lifecycle.mjs
 */

import fs from 'node:fs';
import crypto from 'node:crypto';
import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import {
  JsonRpcProvider, Wallet, Contract,
  parseUnits, formatUnits, getAddress, ZeroHash,
} from 'ethers';

const __here = dirname(fileURLToPath(import.meta.url));
const RPC_URL = process.env.RPC_URL || 'http://localhost:8545';
const ORDER_USD = Number(process.env.ORDER_USD || 1500);
const BROADCAST_LOG = process.env.BROADCAST_LOG
  || resolve(__here, '../contracts/broadcast/DeployLocal.s.sol/84532001/run-latest.json');

if (!fs.existsSync(BROADCAST_LOG)) {
  console.error(`✗ no broadcast log at ${BROADCAST_LOG}`);
  console.error(`  Run:  cd contracts && forge script script/DeployLocal.s.sol --rpc-url ${RPC_URL} --broadcast`);
  process.exit(2);
}

const log = JSON.parse(fs.readFileSync(BROADCAST_LOG, 'utf-8'));
const escrowAddr = log.transactions.find((t) => t.contractName === 'OrderEscrow').contractAddress;
const proxies = log.transactions.filter((t) => t.contractName === 'ERC1967Proxy');
const ssdcAddr = proxies[3].contractAddress; // 4th UUPS proxy is SSDC

// Anvil's deterministic accounts — buyer is anvil[2], seller is anvil[3].
const provider = new JsonRpcProvider(RPC_URL);
const buyer  = new Wallet('0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a', provider);
const seller = new Wallet('0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6', provider);

const SSDC_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function approve(address, uint256) returns (bool)',
];
const ESCROW_ABI = [
  'function lock(bytes32 orderId, address seller, address token, uint128 amount, uint64 deliveryDeadline, uint64 confirmationWindow)',
  'function markDelivered(bytes32 orderId, bytes32 receiptHash)',
  'function release(bytes32 orderId)',
  'function statusOf(bytes32) view returns (uint8)',
];
const ssdcAsBuyer  = new Contract(ssdcAddr,   SSDC_ABI,   buyer);
const ssdc          = new Contract(ssdcAddr,   SSDC_ABI,   provider);
const escrowAsBuyer = new Contract(escrowAddr, ESCROW_ABI, buyer);
const escrowAsSeller = new Contract(escrowAddr, ESCROW_ABI, seller);

// Note: in OrderEscrow.markDelivered, msg.sender must be the buyer or the
// operator (i.e. the *recipient* confirms delivery, not the sender). That
// matches escrow semantics — the seller can't unilaterally claim delivery.
// So Step 3 below uses the buyer wallet, not the seller, even though the
// narrative is "seller delivers".

const STATUS = ['None', 'Locked', 'Delivered', 'Disputed', 'Released', 'Refunded'];
const fmt = (wei) => Number(formatUnits(wei, 18)).toFixed(2);

// ─── Run ────────────────────────────────────────────────────────────────
console.log(`\n━━━ OrderEscrow lifecycle demo — $${ORDER_USD} order ━━━`);
console.log(`  RPC:    ${RPC_URL}`);
console.log(`  escrow: ${escrowAddr}`);
console.log(`  SSDC:   ${ssdcAddr}`);

const buyerStart  = await ssdc.balanceOf(buyer.address);
const sellerStart = await ssdc.balanceOf(seller.address);
console.log(`\nBefore`);
console.log(`  buyer  ${buyer.address}  ${fmt(buyerStart)} SSDC`);
console.log(`  seller ${seller.address}  ${fmt(sellerStart)} SSDC`);

const orderId = '0x' + crypto.randomBytes(32).toString('hex');
const amount = parseUnits(ORDER_USD.toString(), 18);
const now = Math.floor(Date.now() / 1000);

// Explicit nonces. ethers' internal nonce tracking races with anvil's
// pending-pool reporting in CI environments — we hit NONCE_EXPIRED here on
// the first end-to-end CI run because lock used a stale nonce. Fetching
// from chain after each wait() and passing explicitly removes the race.
// Note: only buyer fires txs in this demo (markDelivered + release both
// require msg.sender == buyer per OrderEscrow), so a single counter is
// enough. Seller is a payee, not an actor.
let buyerNonce = await provider.getTransactionCount(buyer.address);

console.log(`\n1. buyer approves escrow as SSDC spender…`);
await (await ssdcAsBuyer.approve(escrowAddr, amount, { nonce: buyerNonce++ })).wait();
console.log(`   ✓ approved $${ORDER_USD}`);

console.log(`\n2. buyer locks $${ORDER_USD} into escrow (orderId ${orderId.slice(0, 18)}…)…`);
const lockTx = await escrowAsBuyer.lock(
  orderId,
  getAddress(seller.address),
  ssdcAddr,
  amount,
  now + 7 * 86400,  // delivery deadline: 7 days
  0,                // confirmation window: 0 → release fires instantly after
                    //   buyer's own markDelivered (no dispute window needed)
  { gasLimit: 400_000n, nonce: buyerNonce++ }
);
const lockRcpt = await lockTx.wait();
console.log(`   ✓ locked  tx ${lockRcpt.hash}  block ${lockRcpt.blockNumber}`);

// Assertions after lock — buyer paid `amount`, escrow holds it, status=Locked
const buyerAfterLock = await ssdc.balanceOf(buyer.address);
const escrowAfterLock = await ssdc.balanceOf(escrowAddr);
const statusAfterLock = await escrowAsBuyer.statusOf(orderId);
assert.equal(buyerStart - buyerAfterLock, amount, 'buyer balance did not decrease by exactly `amount`');
assert.equal(escrowAfterLock, amount, 'escrow did not receive exactly `amount`');
assert.equal(statusAfterLock, 1n, `expected status=Locked(1), got ${STATUS[statusAfterLock]}(${statusAfterLock})`);
console.log(`   ✓ buyer −${fmt(amount)}  escrow +${fmt(amount)}  status=Locked`);

console.log(`\n3. buyer markDelivered (confirms receipt, w/ delivery-receipt hash)…`);
const receiptHash = '0x' + crypto.createHash('sha256').update(`delivered:${orderId}`).digest('hex');
const deliverTx = await escrowAsBuyer.markDelivered(orderId, receiptHash, { gasLimit: 200_000n, nonce: buyerNonce++ });
const deliverRcpt = await deliverTx.wait();
console.log(`   ✓ delivered  tx ${deliverRcpt.hash}  block ${deliverRcpt.blockNumber}`);

// Assertions after markDelivered — funds still in escrow, status=Delivered
const escrowAfterDeliver = await ssdc.balanceOf(escrowAddr);
const statusAfterDeliver = await escrowAsBuyer.statusOf(orderId);
assert.equal(escrowAfterDeliver, amount, 'escrow drained early — funds should remain until release');
assert.equal(statusAfterDeliver, 2n, `expected status=Delivered(2), got ${STATUS[statusAfterDeliver]}(${statusAfterDeliver})`);
console.log(`   ✓ escrow still holds ${fmt(amount)}  status=Delivered`);

console.log(`\n4. seller release() (after confirmation window)…`);
const releaseTx = await escrowAsSeller.release(orderId, { gasLimit: 300_000n });
const releaseRcpt = await releaseTx.wait();
console.log(`   ✓ released  tx ${releaseRcpt.hash}  block ${releaseRcpt.blockNumber}`);

// Assertions after release — escrow empty, seller +amount, status=Released
const buyerEnd  = await ssdc.balanceOf(buyer.address);
const sellerEnd = await ssdc.balanceOf(seller.address);
const escrowEnd = await ssdc.balanceOf(escrowAddr);
const statusFinal = await escrowAsBuyer.statusOf(orderId);
assert.equal(escrowEnd, 0n, 'escrow not drained on release');
assert.equal(sellerEnd - sellerStart, amount, 'seller balance did not increase by exactly `amount`');
assert.equal(buyerStart - buyerEnd, amount, 'buyer net flow ≠ `amount`');
assert.equal(statusFinal, 4n, `expected status=Released(4), got ${STATUS[statusFinal]}(${statusFinal})`);
console.log(`   ✓ escrow drained  seller +${fmt(amount)}  status=Released`);

console.log(`\nAfter`);
console.log(`  buyer  ${fmt(buyerEnd)} SSDC  (Δ ${fmt(buyerEnd - buyerStart)})`);
console.log(`  seller ${fmt(sellerEnd)} SSDC  (Δ +${fmt(sellerEnd - sellerStart)})`);

console.log(`\n✓ escrow lifecycle complete — 8 invariants asserted: buyer paid, escrow held + drained, seller paid, statuses correct.\n`);
