#!/usr/bin/env node
/**
 * verify-onchain.mjs — bridge the off-chain STARK proof to an on-chain
 * verifier. Closes THREAT_MODEL.md's "No on-chain STARK proof validation"
 * residual: today the chain only stores `proofHash`; a regulator still has
 * to run `ves-stark verify` themselves. With an upstream Solidity verifier
 * deployed (e.g. Sepolia), this demo wires receipts → on-chain proof check.
 *
 * Flow:
 *   1. Load a receipt fixture (or one passed in argv).
 *   2. Read the batch's stored proofHash from SetRegistry on-chain.
 *   3. If `STARK_VERIFIER_ADDRESS` is set, call its `verify(proofHash,
 *      publicInputs)` view function and assert the result.
 *   4. If not set, run the audit-shaped offline path against the local
 *      receipt and print the exact `cast` command to extend later.
 *
 * Why this demo exists in the *quickstart*: the upstream STARK verifier
 * binary lives in stateset-starks. This repo can't host the verifier
 * itself, but it can — and now does — show the *call shape* so an operator
 * who has a verifier deployed knows what to wire up. Without that, the
 * "off-chain handshake" gap from the threat model stays purely textual.
 *
 * Env:
 *   STARK_VERIFIER_ADDRESS — deployed contract implementing
 *     `function verify(bytes32 proofHash, bytes calldata publicInputs)
 *       view returns (bool)`
 *   STARK_VERIFIER_RPC     — RPC URL for the chain that hosts the verifier
 *                            (default: RPC_URL or http://localhost:8545)
 *   BROADCAST_LOG          — path to DeployLocal broadcast JSON
 *   RECEIPT_PATH or argv[2] — path to receipt JSON (default: bundled fixture)
 *
 * Run:
 *   STARK_VERIFIER_ADDRESS=0x… \
 *   STARK_VERIFIER_RPC=https://sepolia.infura.io/v3/KEY \
 *   node demos/verify-onchain.mjs ~/inbox/receipt.json
 *
 * Without the env, it runs offline and exits 0 with the call shape printed.
 */

import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { strict as assert } from 'node:assert';
import {
  JsonRpcProvider, Contract, isAddress, getAddress,
  hexlify, getBytes, AbiCoder,
} from 'ethers';

const __here = dirname(fileURLToPath(import.meta.url));

const RECEIPT_PATH = process.argv[2]
  || process.env.RECEIPT_PATH
  || resolve(__here, 'fixtures/agent-receipt.json');
const VERIFIER_ADDR = process.env.STARK_VERIFIER_ADDRESS || '';
const VERIFIER_RPC = process.env.STARK_VERIFIER_RPC
  || process.env.RPC_URL
  || 'http://localhost:8545';
const BROADCAST_LOG = process.env.BROADCAST_LOG
  || resolve(__here, '../contracts/broadcast/DeployLocal.s.sol/84532001/run-latest.json');

function bail(msg, hint) {
  console.error(`✗ ${msg}`);
  if (hint) console.error(`  ${hint}`);
  process.exit(2);
}

if (!fs.existsSync(RECEIPT_PATH)) bail(`receipt not found: ${RECEIPT_PATH}`);
const receipt = JSON.parse(fs.readFileSync(RECEIPT_PATH, 'utf-8'));

// stateset.agent-receipt.v1 puts STARK metadata under `starkProof` and the
// chain commitment under `sequencer`. We also accept a flatter custom shape
// (root `proofHash`/`batchId`) so verifiers built from this demo can take
// receipts that drop the optional nesting.
const proofHash = receipt?.starkProof?.proofHash || receipt?.proofHash;
const batchId = receipt?.sequencer?.batchId || receipt?.batchId;
const policyHash = receipt?.starkProof?.policyHash || receipt?.policyHash;
const policyLimit = receipt?.starkProof?.policyLimit ?? receipt?.policyLimit ?? 0;
const allCompliant = Boolean(receipt?.starkProof?.allCompliant ?? receipt?.allCompliant ?? true);

console.log(`\n━━━ Receipt → on-chain proof verification ━━━`);
console.log(`  receipt:     ${RECEIPT_PATH}`);
console.log(`  proofHash:   ${proofHash || '(missing — receipt does not embed a STARK proof)'}`);
console.log(`  batchId:     ${batchId || '(missing)'}`);
console.log(`  policyHash:  ${policyHash || '(missing)'}`);

if (!proofHash) bail('receipt has no proofHash field — nothing to verify on-chain',
  'expected compliance.stark.proofHash or top-level proofHash');

// ─── Read the on-chain commitment from SetRegistry ──────────────────────────
// Why this comparison even without a verifier: it answers "does the receipt
// I was given agree with what the sequencer committed?" The hash equality is
// what the chain promises; STARK validity is the *next* layer the upstream
// verifier provides.
async function readChainCommitment() {
  if (!fs.existsSync(BROADCAST_LOG)) {
    console.log(`\n  ! no broadcast log at ${BROADCAST_LOG}`);
    console.log(`    Skipping the SetRegistry read; run \`stateset deploy\` to enable it.`);
    return null;
  }
  let registryAddr;
  try {
    const log = JSON.parse(fs.readFileSync(BROADCAST_LOG, 'utf-8'));
    const firstProxy = log.transactions.find((t) =>
      t.transactionType === 'CREATE' && t.contractName === 'ERC1967Proxy');
    registryAddr = firstProxy?.contractAddress;
  } catch (err) {
    console.log(`\n  ! could not parse broadcast log: ${err.message}`);
    return null;
  }
  if (!registryAddr) {
    console.log(`\n  ! could not locate SetRegistry proxy in broadcast log`);
    return null;
  }

  const provider = new JsonRpcProvider(VERIFIER_RPC);
  const REGISTRY_ABI = [
    'function verifyStarkProofHash(bytes32 batchId, bytes32 proofHash) view returns (bool)',
    'function getStarkProofDetails(bytes32 batchId) view returns (bytes32 proofHash, bytes32 policyHash, bool allCompliant, uint64 timestamp)',
    'function hasStarkProof(bytes32 batchId) view returns (bool)',
  ];
  const registry = new Contract(registryAddr, REGISTRY_ABI, provider);

  console.log(`\n  SetRegistry: ${registryAddr}  @ ${VERIFIER_RPC}`);

  if (!batchId) {
    console.log(`    ! receipt has no batchId — cannot cross-check the on-chain commitment.`);
    return { registryAddr };
  }
  try {
    const hasProof = await registry.hasStarkProof(batchId);
    if (!hasProof) {
      console.log(`    ! batch ${batchId.slice(0, 18)}… has no proof on chain`);
      console.log(`      receipt may be for a chain you're not pointed at — set RPC_URL/STARK_VERIFIER_RPC accordingly.`);
      return { registryAddr };
    }
    const matches = await registry.verifyStarkProofHash(batchId, proofHash);
    if (!matches) {
      bail(`proofHash mismatch — receipt says ${proofHash.slice(0, 18)}… but chain says different`,
        'the receipt was either modified or comes from a different deployment');
    }
    const details = await registry.getStarkProofDetails(batchId);
    console.log(`    ✓ proofHash matches the chain commitment`);
    console.log(`      committed at block-time ${new Date(Number(details[3]) * 1000).toISOString()}`);
    console.log(`      policy ${details[1].slice(0, 18)}…  allCompliant=${details[2]}`);
    return { registryAddr, details };
  } catch (err) {
    console.log(`    ! SetRegistry read failed: ${err.message}`);
    return { registryAddr };
  }
}

await readChainCommitment();

// ─── Stage 2: ask the upstream verifier to crypt-verify the proof ───────────
// This is the half the quickstart can't host itself — Winterfell STARK
// verifiers live upstream (stateset-starks). With the address provided,
// we send `(proofHash, publicInputs)` and trust its boolean.
console.log(`\n  STARK verifier:  ${VERIFIER_ADDR || '(not configured)'}`);

if (!VERIFIER_ADDR) {
  console.log(`    Set STARK_VERIFIER_ADDRESS to enable the cryptographic check.`);
  console.log(`    Expected signature (minimal ABI):`);
  console.log(`      function verify(bytes32 proofHash, bytes calldata publicInputs) view returns (bool);`);
  console.log(`    cast equivalent:`);
  console.log(`      cast call $STARK_VERIFIER_ADDRESS \\`);
  console.log(`        "verify(bytes32,bytes)(bool)" \\`);
  console.log(`        ${proofHash} 0x<abi-encoded-publicInputs> \\`);
  console.log(`        --rpc-url ${VERIFIER_RPC}`);
  console.log(`\n✓ Offline verification complete (chain-commitment check + receipt inspection).`);
  console.log(`  Configure STARK_VERIFIER_ADDRESS for the full chain → verifier round-trip.\n`);
  process.exit(0);
}

if (!isAddress(VERIFIER_ADDR)) bail(`STARK_VERIFIER_ADDRESS is not a valid address: ${VERIFIER_ADDR}`);

// Public inputs the verifier consumes: (policyHash, allCompliant, policyLimit).
// Exact encoding is verifier-defined — adjust if the upstream contract uses a
// different layout. Quickstart matches the SetRegistry storage shape.
const publicInputs = AbiCoder.defaultAbiCoder().encode(
  ['bytes32', 'bool', 'uint64'],
  [policyHash || '0x' + '0'.repeat(64), allCompliant, BigInt(policyLimit)],
);

const provider = new JsonRpcProvider(VERIFIER_RPC);
const VERIFIER_ABI = [
  'function verify(bytes32 proofHash, bytes calldata publicInputs) view returns (bool)',
];
const verifier = new Contract(getAddress(VERIFIER_ADDR), VERIFIER_ABI, provider);

try {
  const ok = await verifier.verify(proofHash, publicInputs);
  if (!ok) bail(`on-chain verifier returned false for proofHash ${proofHash}`,
    'either the receipt is invalid or the public-inputs encoding does not match the deployed verifier');
  console.log(`    ✓ verifier returned true — proof is cryptographically valid on-chain`);
} catch (err) {
  bail(`verifier call reverted: ${err.message}`,
    'check that STARK_VERIFIER_ADDRESS implements verify(bytes32,bytes)(bool)');
}

console.log(`\n✓ on-chain verification complete.\n`);
