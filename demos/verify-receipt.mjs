#!/usr/bin/env node
/**
 * verify-receipt.mjs — independent audit of any StateSet receipt.
 *
 * Takes a receipt JSON path (agent-receipt-*.json, cross-border-*.json,
 * compliance-bundle-*.json) and re-verifies every claim against the live
 * chain. For compliance bundles it also re-runs the STARK verifier on
 * each policy proof (binary-level, off-chain).
 *
 * Exits 0 if every claim verifies, 1 otherwise.
 *
 * Usage:
 *   node ves-demo/verify-receipt.mjs <receipt.json>
 *   node ves-demo/verify-receipt.mjs ves-demo/agent-receipt-ORD-XXX.json
 */

import fs from 'node:fs';
import { execFileSync, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import {
  JsonRpcProvider, Contract,
  formatUnits, keccak256, toUtf8Bytes,
} from 'ethers';

const execFileAsync = promisify(execFile);

// `ves-stark` is built from the stateset-starks repo. Set STARK_BIN to its
// absolute path, or rely on PATH lookup (default).
const STARK_BIN = process.env.STARK_BIN || 'ves-stark';
const ANVIL_URL = process.env.RPC_URL || 'http://localhost:8545';

const C = {
  reset: '\x1b[0m', bold: '\x1b[1m', dim: '\x1b[2m',
  red: '\x1b[31m', green: '\x1b[32m', yellow: '\x1b[33m',
  cyan: '\x1b[36m',
};

const STATUS_NAMES = ['None', 'Locked', 'Delivered', 'Disputed', 'Released', 'Refunded'];

const ESCROW_ABI = [
  'function statusOf(bytes32) view returns (uint8)',
  'function orders(bytes32) view returns (address buyer, address seller, address token, uint128 amount, uint64 lockedAt, uint64 deliveredAt, uint64 deliveryDeadline, uint64 confirmationWindow, bytes32 deliveryReceiptHash, uint8 status, address feeRecipient, uint16 feeBps)',
];
const REGISTRY_ABI = [
  'function getBatchCommitment(bytes32) view returns (tuple(bytes32 eventsRoot, bytes32 newStateRoot, uint64 sequenceStart, uint64 sequenceEnd, uint32 eventCount, uint64 timestamp))',
  'function getStarkProofDetails(bytes32) view returns (bytes32 proofHash, bytes32 policyHash, bool allCompliant, uint64 timestamp)',
  'function hasStarkProof(bytes32) view returns (bool)',
];
const FX_ABI = [
  'function getQuote(bytes32 pair) view returns (uint256 rate, uint64 updatedAt)',
];

const path = process.argv[2];
if (!path) {
  console.error('usage: node verify-receipt.mjs <receipt.json>');
  process.exit(2);
}
if (!fs.existsSync(path)) {
  console.error(`error: file not found: ${path}`);
  process.exit(2);
}

const receipt = JSON.parse(fs.readFileSync(path, 'utf-8'));
const provider = new JsonRpcProvider(ANVIL_URL);

console.log(`\n${C.cyan}╔${'═'.repeat(70)}╗`);
console.log(`║  ${C.bold}VERIFY RECEIPT — independent audit against live chain${C.reset}${C.cyan}${' '.repeat(15)}║`);
console.log(`╚${'═'.repeat(70)}╝${C.reset}`);
console.log(`\n  ${C.dim}file:   ${C.reset}${path}`);
console.log(`  ${C.dim}schema: ${C.reset}${receipt.schema}`);

let checks = 0, passed = 0;
const note = (label, ok, detail = '') => {
  checks++;
  if (ok) passed++;
  const tag = ok ? `${C.green}✓${C.reset}` : `${C.red}✗${C.reset}`;
  console.log(`  ${tag} ${label}${detail ? `  ${C.dim}${detail}${C.reset}` : ''}`);
};

async function verifyTx(label, hash) {
  if (!hash) return note(label, false, 'no tx hash in receipt');
  try {
    const rcpt = await provider.getTransactionReceipt(hash);
    if (!rcpt) return note(label, false, 'tx not found on chain');
    const ok = rcpt.status === 1;
    note(label, ok, `block ${rcpt.blockNumber}, gas ${rcpt.gasUsed}`);
  } catch (err) {
    note(label, false, err.message);
  }
}

// ─── Schema-specific checks ────────────────────────────────────────────────
async function verifyAgentReceipt(r) {
  console.log(`\n${C.bold}1. On-chain transactions${C.reset}`);
  await verifyTx('escrow.lock tx',          r.escrow.lockTx);
  await verifyTx('escrow.markDelivered tx', r.escrow.deliverTx);
  if (r.escrow.releaseTx) await verifyTx('escrow.release tx', r.escrow.releaseTx);
  await verifyTx('SetRegistry.commitBatchWithStarkProof tx', r.anchor.anchorTx);

  console.log(`\n${C.bold}2. Escrow state${C.reset}`);
  const escrow = new Contract(r.escrow.contract, ESCROW_ABI, provider);
  try {
    const status = STATUS_NAMES[Number(await escrow.statusOf(r.escrow.orderIdHash))];
    note(`escrow.statusOf(orderIdHash) == receipt.escrow.finalStatus`,
         status === r.escrow.finalStatus,
         `chain=${status}, receipt=${r.escrow.finalStatus}`);

    const o = await escrow.orders(r.escrow.orderIdHash);
    const expectedAmt = BigInt(r.payment.amountUnits);
    note('escrow.orders.amount matches receipt.payment.amountUnits',
         o.amount === expectedAmt,
         `chain=${o.amount}, receipt=${expectedAmt}`);
    note('escrow.orders.buyer matches receipt.parties.buyer.wallet',
         o.buyer.toLowerCase() === r.parties.buyer.wallet.toLowerCase());
    note('escrow.orders.seller matches receipt.parties.seller.wallet',
         o.seller.toLowerCase() === r.parties.seller.wallet.toLowerCase());
    note('escrow.orders.deliveryReceiptHash matches receipt',
         o.deliveryReceiptHash === r.escrow.deliveryReceiptHash);
    if (r.escrow.marketplace) {
      note(`escrow.orders.feeRecipient (marketplace) == receipt`,
           o.feeRecipient.toLowerCase() === r.escrow.marketplace.feeRecipient.toLowerCase(),
           `${o.feeRecipient}`);
      note('escrow.orders.feeBps matches receipt',
           Number(o.feeBps) === r.escrow.marketplace.feeBps,
           `chain=${o.feeBps}, receipt=${r.escrow.marketplace.feeBps}`);
    }
  } catch (err) {
    note('escrow read', false, err.message);
  }

  console.log(`\n${C.bold}3. SetRegistry batch + STARK proof${C.reset}`);
  const registry = new Contract(r.anchor.registry, REGISTRY_ABI, provider);
  try {
    const batch = await registry.getBatchCommitment(r.sequencer.batchId);
    note('SetRegistry.commitments[batch].eventsRoot matches',
         batch.eventsRoot === r.sequencer.eventsRoot,
         `${batch.eventsRoot.slice(0, 22)}…`);
    note('SetRegistry.hasStarkProof(batch) is true',
         await registry.hasStarkProof(r.sequencer.batchId));
    const sp = await registry.getStarkProofDetails(r.sequencer.batchId);
    note('SetRegistry.starkProofs[batch].proofHash matches receipt',
         sp.proofHash === r.starkProof.proofHash,
         `${sp.proofHash.slice(0, 22)}…`);
    note('SetRegistry.starkProofs[batch].policyHash matches receipt',
         sp.policyHash === r.starkProof.policyHash);
    note('SetRegistry.starkProofs[batch].allCompliant is true',
         sp.allCompliant);
  } catch (err) {
    note('SetRegistry read', false, err.message);
  }
}

async function verifyCrossBorder(r) {
  console.log(`\n${C.bold}1. On-chain transactions${C.reset}`);
  await verifyTx('escrow.lock tx',    r.txs?.lock);
  await verifyTx('escrow.release tx', r.txs?.release);

  console.log(`\n${C.bold}2. FX quote on chain${C.reset}`);
  const fxAddr = r.fxBinding.oracle;
  const fx = new Contract(fxAddr, FX_ABI, provider);
  try {
    const [rate, updatedAt] = await fx.getQuote(r.fxBinding.pairId);
    note(`FxOracle.getQuote(${r.fxBinding.pair}).rate matches receipt`,
         rate.toString() === r.fxBinding.rateE18,
         `chain=${rate}, receipt=${r.fxBinding.rateE18}`);
    note('FxOracle quote was fresh at receipt time',
         Number(updatedAt) === r.fxBinding.quoteUpdatedAt);
  } catch (err) {
    note('FxOracle read', false, err.message + ' (may be stale by now — that\'s expected for old receipts)');
  }
}

async function verifyComplianceBundle(r) {
  console.log(`\n${C.bold}1. Underlying transaction${C.reset}`);
  await verifyTx('escrow.lock tx',    r.transaction.lockTx);
  await verifyTx('escrow.release tx', r.transaction.releaseTx);

  console.log(`\n${C.bold}2. STARK proof bundle (${r.proofs.length} policies)${C.reset}`);
  for (const proof of r.proofs) {
    const pi = proof.publicInputs;
    note(`${proof.policy} — policyId in publicInputs matches`,
         pi.policyId === proof.policy);

    // Cryptographic verification: re-run the Winterfell verifier on the
    // canonical proof file. This is the strongest possible audit — it
    // checks the proof bytes are mathematically valid against the claimed
    // public inputs and policy bound, no trust in receipt fields needed.
    if (!proof.proofFilePath || !fs.existsSync(proof.proofFilePath)) {
      note(`${proof.policy} — STARK verify`, false,
           proof.proofFilePath ? `proof file missing: ${proof.proofFilePath}` : 'no proofFilePath in receipt');
      continue;
    }
    const args = [
      'verify',
      '--proof', proof.proofFilePath,
      '--policy', proof.policy,
      '--limit', String(proof.limit),
    ];
    if (proof.policy === 'agent.authorization.v1' && proof.intentHash) {
      args.push('--intent-hash', proof.intentHash);
    }
    try {
      const t0 = Date.now();
      const out = execFileSync(STARK_BIN, args, { stdio: ['ignore', 'pipe', 'pipe'] }).toString();
      const ok = out.includes('VALID') || out.includes('Proof VALID');
      const ms = Date.now() - t0;
      const sizeBytes = fs.statSync(proof.proofFilePath).size;
      note(`${proof.policy} — STARK verify`, ok,
           ok ? `cryptographically valid (${ms}ms, ${(sizeBytes / 1024).toFixed(1)}KB proof file)` : 'verifier rejected');
    } catch (err) {
      const detail = (err.stderr?.toString() || err.stdout?.toString() || err.message).slice(0, 140).replace(/\n/g, ' ');
      note(`${proof.policy} — STARK verify`, false, detail);
    }
  }
}

// ─── Dispatch by schema ────────────────────────────────────────────────────
try {
  switch (receipt.schema) {
    case 'stateset.agent-receipt.v1':       await verifyAgentReceipt(receipt); break;
    case 'stateset.cross-border-receipt.v1': await verifyCrossBorder(receipt); break;
    case 'stateset.compliance-bundle.v1':   await verifyComplianceBundle(receipt); break;
    default:
      console.log(`\n${C.yellow}Unknown schema; printing structural summary only${C.reset}`);
      console.log(JSON.stringify(receipt, null, 2).slice(0, 1000));
      process.exit(2);
  }
} catch (err) {
  console.error(`\n${C.red}fatal:${C.reset} ${err.message}`);
  process.exit(1);
}

console.log('');
const allOk = passed === checks;
const verdict = allOk
  ? `${C.green}${C.bold}✓ All ${checks} claims verified against live chain.${C.reset}`
  : `${C.red}${C.bold}✗ ${checks - passed} of ${checks} checks failed.${C.reset}`;
console.log(verdict);

// Machine-readable summary for the MCP wrapper (agent_receipt_audit). Emit
// only when explicitly requested so interactive runs stay clean.
if (process.argv.includes('--json')) {
  process.stdout.write('\n--JSON--\n' + JSON.stringify({
    schema: receipt.schema,
    file: path,
    checksTotal: checks,
    checksPassed: passed,
    allOk,
  }) + '\n');
}
process.exit(allOk ? 0 : 1);
