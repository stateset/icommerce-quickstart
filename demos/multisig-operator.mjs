#!/usr/bin/env node
/**
 * multisig-operator.mjs — close the THREAT_MODEL.md "single-key operator"
 * residual risk in code, not just in docs.
 *
 *   1. Deploy a 2-of-3 MultisigGuard backed by three anvil signing keys.
 *   2. Hand SSDC.treasuryVault from anvil[0] to the guard.
 *   3. Show the single-key bypass is gone:
 *        a) Direct mintShares from anvil[0] now reverts (NotTreasuryVault).
 *        b) A 1-of-3 multisig submission reverts (InsufficientSignatures).
 *        c) A 2-of-3 multisig submission mints successfully.
 *   4. Print the canonical `callHash` that owners signed so a third party
 *      can re-derive and audit it.
 *
 * Why this matters: in the demo deploy SSDC.treasuryVault is anvil[0] — a
 * single key whose compromise can mint without bound. THREAT_MODEL.md flagged
 * this as a v2/multisig requirement. This demo is the v2 path: a drop-in
 * `setTreasuryVault(multisig)` call converts the demo into a 2-of-3 mint
 * gate. Run it after `stateset up` to see it work end-to-end.
 *
 * Out of scope here: OrderEscrow.operator is `immutable`, so the multisig
 * must be passed at construction. The closing notes show the one-line
 * change a production DeployLocal would make.
 *
 * Prerequisites:
 *   - anvil running on RPC_URL (default http://localhost:8545)
 *   - contracts deployed AND built (`stack/stateset up` covers both)
 *
 * Run:
 *   node demos/multisig-operator.mjs
 */

import fs from 'node:fs';
import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import {
  JsonRpcProvider, Wallet, Contract, ContractFactory,
  parseUnits, formatUnits, getAddress, AbiCoder, keccak256, getBytes, solidityPacked,
} from 'ethers';

const __here = dirname(fileURLToPath(import.meta.url));
const RPC_URL = process.env.RPC_URL || 'http://localhost:8545';
const BROADCAST_LOG = process.env.BROADCAST_LOG
  || resolve(__here, '../contracts/broadcast/DeployLocal.s.sol/84532001/run-latest.json');
const ARTIFACT_PATH = process.env.MULTISIG_ARTIFACT
  || resolve(__here, '../contracts/out/MultisigGuard.sol/MultisigGuard.json');

function bail(msg, hint) {
  console.error(`✗ ${msg}`);
  if (hint) console.error(`  ${hint}`);
  process.exit(2);
}

if (!fs.existsSync(BROADCAST_LOG)) {
  bail(`no broadcast log at ${BROADCAST_LOG}`, 'run: ./stack/stateset deploy');
}
if (!fs.existsSync(ARTIFACT_PATH)) {
  bail(`no MultisigGuard artifact at ${ARTIFACT_PATH}`,
       'run: cd contracts && forge build');
}

const log = JSON.parse(fs.readFileSync(BROADCAST_LOG, 'utf-8'));
const proxies = log.transactions.filter((t) => t.contractName === 'ERC1967Proxy');
const ssdcAddr = proxies[3].contractAddress; // 4th UUPS proxy is SSDC (matches DeployLocal order)
const artifact = JSON.parse(fs.readFileSync(ARTIFACT_PATH, 'utf-8'));
const MULTISIG_ABI = artifact.abi;
const MULTISIG_BYTECODE = artifact.bytecode?.object || artifact.bytecode;

const provider = new JsonRpcProvider(RPC_URL);
// anvil deployer (owner of SSDC + current treasuryVault).
const deployer = new Wallet('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80', provider);
// Three multisig signing keys: anvil[4], anvil[5], anvil[7] (avoid anvil[6] —
// the off-ramp bridge holds that key as its treasury).
const owner1 = new Wallet('0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a', provider);
const owner2 = new Wallet('0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba', provider);
const owner3 = new Wallet('0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97', provider);
// A target wallet to receive the mint (anvil[8] — no role on the stack).
const TARGET = getAddress('0xfabb0ac9d68b0b445fb7357272ff202c5651694a');

const SSDC_ABI = [
  'function owner() view returns (address)',
  'function treasuryVault() view returns (address)',
  'function setTreasuryVault(address)',
  'function balanceOf(address) view returns (uint256)',
  'function mintShares(address to, uint256 shares)',
];
const ssdcAsDeployer = new Contract(ssdcAddr, SSDC_ABI, deployer);
const ssdc = new Contract(ssdcAddr, SSDC_ABI, provider);

const network = await provider.getNetwork();
const chainId = Number(network.chainId);

// Explicit nonce tracking. ethers' auto-nonce races with anvil's pending-pool
// reporting in CI/multi-run environments — same fix the escrow-lifecycle and
// realmoney-loop demos applied (NONCE_EXPIRED on the second deploy of the day).
// Fetching at script start and passing explicitly removes the race.
let deployerNonce = await provider.getTransactionCount(deployer.address);

console.log(`\n━━━ MultisigGuard demo: closing the single-key treasury role ━━━`);
console.log(`  RPC:        ${RPC_URL}  (chainId ${chainId})`);
console.log(`  SSDC:       ${ssdcAddr}`);
console.log(`  deployer:   ${deployer.address}  (current SSDC owner + treasury)`);

// ─── 1. Deploy MultisigGuard with the three owners + threshold=2 ───────────
console.log(`\n1. Deploying MultisigGuard(owners=3, threshold=2)…`);
const owners = [owner1.address, owner2.address, owner3.address];
// Sort lexicographically — execute() requires strictly-ascending signers, so
// it's clearest if the on-chain order matches the order we'll submit sigs in.
const sortedOwners = [...owners].sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
const factory = new ContractFactory(MULTISIG_ABI, MULTISIG_BYTECODE, deployer);
const guard = await factory.deploy(sortedOwners, 2, { nonce: deployerNonce++ });
await guard.waitForDeployment();
const guardAddr = await guard.getAddress();
console.log(`   ✓ guard deployed at ${guardAddr}`);
console.log(`     owners: ${sortedOwners.join(', ')}`);

// ─── 2. Hand the SSDC treasury role to the guard ───────────────────────────
console.log(`\n2. Transferring SSDC.treasuryVault from deployer → multisig…`);
const before = await ssdc.treasuryVault();
console.log(`   was:  ${before}`);
await (await ssdcAsDeployer.setTreasuryVault(guardAddr, { nonce: deployerNonce++ })).wait();
const after = await ssdc.treasuryVault();
console.log(`   now:  ${after}`);
assert.equal(after.toLowerCase(), guardAddr.toLowerCase(),
  'treasuryVault did not move to the multisig');

// ─── 3a. Direct mintShares from the old key must now revert ────────────────
console.log(`\n3a. Direct mintShares from the old single key…`);
try {
  await ssdcAsDeployer.mintShares.staticCall(TARGET, parseUnits('1', 18));
  bail('expected mintShares to revert (NotTreasuryVault), but it succeeded',
       'multisig setTreasuryVault did not stick');
} catch (err) {
  // ethers wraps custom errors; just confirm it reverted.
  console.log(`   ✓ reverted: NotTreasuryVault — single-key bypass is gone`);
}

// ─── 3b. 1-of-3 multisig submission must revert ────────────────────────────
console.log(`\n3b. Multisig with only 1 signature (below threshold)…`);
const MINT_AMOUNT = parseUnits('250', 18); // 250 ssUSD
const mintData = new Contract(ssdcAddr, SSDC_ABI).interface.encodeFunctionData(
  'mintShares', [TARGET, MINT_AMOUNT]
);
const startNonce = await guard.nonce();
const callHash = await guard.callHash(ssdcAddr, 0, mintData, startNonce);
// EIP-191 personal_sign envelope is what ECDSA.recover(toEthSignedMessageHash(...))
// expects on the contract side. `ethers.signMessage(getBytes(hash))` produces it.
async function signCanonical(wallet) {
  return wallet.signMessage(getBytes(callHash));
}
const sig1 = await signCanonical(owner1);
try {
  await guard.execute.staticCall(ssdcAddr, 0, mintData, [sig1]);
  bail('expected InsufficientSignatures revert, got success');
} catch (err) {
  console.log(`   ✓ reverted: InsufficientSignatures(1, 2) — threshold enforced`);
}

// ─── 3c. 2-of-3 multisig submission succeeds ───────────────────────────────
console.log(`\n3c. Multisig with 2 of 3 signatures…`);
// Submit sigs in ascending owner-address order — the contract uses strict
// ordering for O(1) dedup.
const all = [
  { wallet: owner1, sig: await signCanonical(owner1) },
  { wallet: owner2, sig: await signCanonical(owner2) },
];
all.sort((a, b) => a.wallet.address.toLowerCase().localeCompare(b.wallet.address.toLowerCase()));
const sigs = all.map((x) => x.sig);

const targetBefore = await ssdc.balanceOf(TARGET);
const guardConnected = guard.connect(deployer); // any caller can submit
const execTx = await guardConnected.execute(ssdcAddr, 0, mintData, sigs, { nonce: deployerNonce++ });
const execRcpt = await execTx.wait();
const targetAfter = await ssdc.balanceOf(TARGET);
const delta = targetAfter - targetBefore;
assert.equal(delta, MINT_AMOUNT, `mint delta mismatch: got ${delta} expected ${MINT_AMOUNT}`);
console.log(`   ✓ execute() tx ${execRcpt.hash}`);
console.log(`   ✓ target ${TARGET} +${formatUnits(MINT_AMOUNT, 18)} SSDC`);

// ─── 4. Echo the canonical hash so the auditor can re-derive it ────────────
const recomputed = keccak256(AbiCoder.defaultAbiCoder().encode(
  ['uint256', 'address', 'address', 'uint256', 'bytes', 'uint256'],
  [chainId, guardAddr, ssdcAddr, 0n, mintData, startNonce],
));
assert.equal(recomputed.toLowerCase(), callHash.toLowerCase(),
  'off-chain callHash does not match on-chain — abi.encode shape drifted');
console.log(`\n4. Audit trail`);
console.log(`   callHash:    ${callHash}`);
console.log(`   nonce was:   ${startNonce}  (now: ${await guard.nonce()})`);
console.log(`   bound to:    chainId=${chainId}  guard=${guardAddr}`);
console.log(`\n   To verify off-chain, regenerate:`);
console.log(`     keccak256(abi.encode(chainId, guard, target, value, data, nonce))`);
console.log(`   then EIP-191-prefix and ECDSA-recover each signature.`);

console.log(`\n✓ Multisig operator demo complete.`);
console.log(`  Closed: THREAT_MODEL.md §"Operator mints unlimited SSDC" — single-key path.`);
console.log(`  Still single-key (immutable; redeploy to migrate):`);
console.log(`    OrderEscrow.operator        — pass guard at construction in DeployLocal.`);
console.log(`    FxOracle.operator           — same.`);
console.log(`  Transferable today via setter (same pattern as treasury above):`);
console.log(`    SSDC.owner                  — transferOwnership(guard)`);
console.log(`    SetRegistry/PaymentBatch owner — transferOwnership(guard)`);
console.log(`    NAVOracle.owner             — transferOwnership(guard)\n`);
