# Deploying to Sepolia

A 7-step runbook for deploying the StateSet iCommerce stack to a public testnet. Mainnet uses the same flow with different RPC + chain id.

The `stack/stateset deploy:sepolia` subcommand wraps everything below; this doc explains what it does and the operational concerns it doesn't.

---

## What this gives you

A live deploy of all 6 contracts plus `MockSsUSD` on Sepolia, with admin/operator roles split across 5 distinct addresses (so a real ops team can hand each role to a multi-sig instead of running everything from one EOA).

| Contract | Role | Initial holder |
|---|---|---|
| `SetRegistry` (UUPS) | batch state-root + STARK metadata | `OWNER_ADDRESS` |
| `OrderEscrow` | 5-state lifecycle | `ESCROW_OPERATOR_ADDRESS` |
| `FxOracle` | per-pair FX with TTL | `FX_OPERATOR_ADDRESS` |
| `SSDC` (UUPS) | rebasing T-bill-backed stablecoin | `OWNER_ADDRESS` (admin) + `TREASURY_ADDRESS` (mint authority) |
| `NAVOracle` (UUPS) | NAV updates for SSDC | `OWNER_ADDRESS` (admin) + `NAV_ATTESTOR_ADDRESS` (poster) |
| `SetPaymaster` (UUPS) | x402 batch settlement | `OWNER_ADDRESS` (admin) + `SEQUENCER_ADDRESS` |
| `SetPaymentBatch` (UUPS) | batch executor | `OWNER_ADDRESS` (admin) + `SEQUENCER_ADDRESS` |
| `MockSsUSD` | test ERC20 — replace with real USDC for prod | none (public mint, demo only) |

**Production note**: `MockSsUSD` is a test stablecoin with public `mint()`. For mainnet, set `USDC_ADDRESS` to the real USDC and the deploy script will skip `MockSsUSD`.

---

## Prerequisites

1. **A funded Sepolia EOA** — needs ~0.05 SepETH for the full deploy. [Sepolia faucet](https://sepoliafaucet.com).
2. **Five distinct wallet addresses** — `OWNER`, `SEQUENCER`, `ESCROW_OPERATOR`, `FX_OPERATOR`, `NAV_ATTESTOR`, `TREASURY`. **`OWNER` must NOT equal the deployer EOA**; the script enforces this.
3. **A Sepolia RPC URL** — Alchemy / Infura / your own node.
4. **An Etherscan API key** — for verification.
5. **Foundry installed** — `forge` + `cast` on PATH.

---

## Step 1 — Set env

```bash
export SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY"
export ETHERSCAN_API_KEY="..."

export DEPLOYER_PRIVATE_KEY="0x..."   # the EOA that pays gas
export OWNER_ADDRESS="0x..."          # admin of upgradeable proxies (multi-sig)
export SEQUENCER_ADDRESS="0x..."      # SetRegistry / SetPaymentBatch sequencer
export ESCROW_OPERATOR_ADDRESS="0x..." # OrderEscrow operator (disputes, sweepYield)
export FX_OPERATOR_ADDRESS="0x..."    # FxOracle quote poster
export NAV_ATTESTOR_ADDRESS="0x..."   # NAVOracle initial attestor
export TREASURY_ADDRESS="0x..."       # SSDC treasury vault (only address that can mint)
```

> **Don't** set these in `.bashrc`. Use a `.env.sepolia` file outside the repo, source it, then deploy in that shell.

---

## Step 2 — Verify your env

```bash
./stack/stateset deploy:sepolia
```

The wrapper checks every var is set, refuses to proceed if `OWNER_ADDRESS` equals the deployer EOA, prints the full role assignment, and prompts for `deploy` confirmation:

```
About to deploy to Sepolia.
  RPC URL:           https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
  Deployer:          0xAbC...
  Owner (admin):     0xDef...   ← must be a multi-sig in production
  Sequencer:         0x...
  ...

Type 'deploy' to confirm, anything else to abort:
```

Anything other than `deploy` aborts.

---

## Step 3 — Deploy

After confirmation the wrapper runs:

```bash
forge script script/DeploySepolia.s.sol:DeploySepolia \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

Each contract is deployed and verified on Etherscan in one go. Output prints the addresses and the `export AGENT_RECEIPT_*` lines you can paste into your demo env.

Total time: ~2-3 minutes per ETH RPC.

---

## Step 4 — Hand off ownership

The deployer EOA temporarily owns each UUPS proxy. Immediately after deploy, **transfer ownership to your multi-sig**:

```bash
cast send "$REGISTRY"  "transferOwnership(address)" "$MULTISIG" --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$SEPOLIA_RPC_URL"
cast send "$SSDC"      "transferOwnership(address)" "$MULTISIG" --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$SEPOLIA_RPC_URL"
cast send "$NAV"       "transferOwnership(address)" "$MULTISIG" --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$SEPOLIA_RPC_URL"
cast send "$PAYMASTER" "transferOwnership(address)" "$MULTISIG" --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$SEPOLIA_RPC_URL"
cast send "$PAYMENTS"  "transferOwnership(address)" "$MULTISIG" --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$SEPOLIA_RPC_URL"
```

OZ v5 OwnableUpgradeable is two-step: the multi-sig must `acceptOwnership()` from each contract.

---

## Step 5 — Seed FX quotes

The local-dev path's `seed-fx` script doesn't apply on Sepolia (different deploy log path). Adapt:

```bash
cast send "$FX_ORACLE" "postQuote(bytes32,uint256,uint64)" \
  "$(cast keccak EUR/ssUSD)" "1062500000000000000" 3600 \
  --private-key "$FX_OPERATOR_PRIVATE_KEY" --rpc-url "$SEPOLIA_RPC_URL"
# repeat for GBP, JPY, MXN
```

In production this is run by a quote-fetcher cron, not a one-shot.

---

## Step 6 — Smoke-test from the new deploy

```bash
RPC_URL="$SEPOLIA_RPC_URL" \
BROADCAST_LOG="contracts/broadcast/DeploySepolia.s.sol/11155111/run-latest.json" \
node demos/escrow-lifecycle.mjs
```

The demo's lazy-loaded contract addresses pick up the Sepolia deploy. If escrow-lifecycle passes against Sepolia, the deploy is healthy.

---

## Step 7 — Tag the deploy

Record what's deployed where:

```bash
git tag -a sepolia-2026-05-07 -m "Sepolia deploy: SSDC=0x..., escrow=0x..., ..."
git push origin sepolia-2026-05-07
```

So someone reading your repo six months from now knows which addresses are live.

---

## What this doesn't do

- **It doesn't set up the sequencer.** The sequencer is a separate Rust service ([stateset/stateset-sequencer](https://github.com/stateset/stateset-sequencer)). After contract deploy, point the sequencer at the new `SetRegistry` address and authorize its EOA.
- **It doesn't deploy the bridges.** The bridges are Node servers ([`bridges/`](../bridges)). Run them on a host you control with the right env vars (RPC_URL, BRIDGE_TREASURY_KEY, BROADCAST_LOG).
- **It doesn't transfer SSDC mint authority** to a real treasury vault contract. The deploy sets `TREASURY_ADDRESS` as the only address that can `mintShares`; in production this should be a contract (e.g. `TreasuryVault` from the upstream monorepo's `stablecoin/` extras), not an EOA.
- **It doesn't seed initial NAV.** Once deployed, the `NAV_ATTESTOR_ADDRESS` must call `attestNAV(...)` once to set NAV $1.00 before any rebases work.

---

## Reverting a bad deploy

UUPS proxies can be upgraded but can't be undone. If a deploy is broken:

1. Don't transfer ownership to the multi-sig (Step 4) yet — keep the deployer key authoritative.
2. Use `pause()` (where available) to halt user actions.
3. Either upgrade with a fixed implementation, or accept that those addresses are dead and re-deploy.

This is why **OWNER ≠ DEPLOYER** is enforced and why ownership-transfer is a separate Step 4 — keep deploys recoverable until you've confirmed they're healthy.
