# demos — exercise the stack end-to-end

Five runnable scripts, plus a bundled fixture receipt for offline auditing. **`escrow-lifecycle` and `realmoney-loop` carry 17 invariant assertions between them**; both run on every CI push.

| Demo | What it does | Prereqs |
|---|---|---|
| **`escrow-lifecycle.mjs`** | The simplest possible end-to-end test: buyer locks SSDC, **buyer markDelivered** (recipient confirms), seller release. ~120 lines of ethers + the deployed contracts. **9 invariant assertions** at each state transition. | anvil + `forge script DeployLocal --broadcast` |
| **`realmoney-loop.mjs`** | Full `bank → SSDC → escrow → SSDC → bank` cycle. Spawns both bridges, sends mock Stripe events, runs the escrow lifecycle, signs a payout. Multi-currency: `--currency JPY --payout-currency GBP`. **8 invariant assertions** per phase. | as above + bridges available |
| **`verify-receipt.mjs`** | Independent audit of a receipt — schema, on-chain claims, optional STARK byte-level. No StateSet-server dependency. | RPC reachable; `STARK_BIN=` for compliance bundles |
| **`validate-fixture.mjs`** | Pure schema validation (Draft 2020-12 via ajv). Used by CI as a fast (~10 ms) gate before the slow e2e path. | none — runs offline |
| **`audit-with-cast.sh`** | Same audit as `verify-receipt`, but pure shell + `jq` + `cast` (no Node). | as above |

## Run

```bash
npm install

# 1. The simplest one — confirms the stack is healthy (9 assertions inline)
node escrow-lifecycle.mjs
ORDER_USD=500 node escrow-lifecycle.mjs

# 2. The full multi-process cycle (8 assertions per phase)
node realmoney-loop.mjs
node realmoney-loop.mjs --currency JPY --payout-currency GBP

# 3. Verify the bundled fixture (or any receipt you have)
node verify-receipt.mjs fixtures/agent-receipt.json
bash audit-with-cast.sh fixtures/agent-receipt.json

# 4. Schema-only check (fast; doesn't need anvil)
node validate-fixture.mjs
```

Or use the orchestrator: `../stack/stateset demo lifecycle` / `../stack/stateset audit` / `../stack/stateset receipts`.

## Producing real receipts

This repo gives you the audit + verify side. The **producer** of receipts (the agent-receipt generator that mints a STARK-proven receipt with full sequencer batch + Merkle inclusion path) lives in the upstream [`icommerce-app`](https://github.com/stateset/icommerce-app) monorepo because it depends on the sequencer + the sync engine that sits on top of VES events.

For most users that's fine — you'll receive receipts from a producer (a partner, a marketplace, a buyer's agent), then verify them locally with `verify-receipt.mjs` or one of the SDKs:

- **Node:** `npm install @stateset/verify-receipt` → `import { verifyReceipt } from '@stateset/verify-receipt'`
- **Python:** `pip install stateset-verify-receipt` → `from stateset_verify_receipt import verify_receipt`

## Env

| Var | Default | Used by |
|---|---|---|
| `RPC_URL` / `ANVIL_URL` | `http://localhost:8545` | all demos |
| `BROADCAST_LOG` | `../contracts/broadcast/DeployLocal.s.sol/84532001/run-latest.json` | escrow-lifecycle, realmoney-loop |
| `STARK_BIN` | `ves-stark` (PATH lookup) | verify-receipt, audit-with-cast |
| `ORDER_USD` | 1500 | escrow-lifecycle |
