# contracts — StateSet iCommerce Solidity workspace

The on-chain protocol layer. Foundry-shape: `foundry.toml` at the workspace root, contracts in `commerce/` + `stablecoin/` + `SetRegistry.sol`, deploy scripts in `script/`, tests in `test/`.

## Setup

From the repo root:

```bash
bash stack/setup.sh    # one-shot — installs forge libs + npm deps everywhere
```

Or manually, just for `contracts/`:

```bash
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts@v5.0.0
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.0.0
forge build
forge test     # 216 tests across 6 contracts
```

`lib/` is gitignored (standard Foundry pattern); these `forge install` commands populate it. Pin OpenZeppelin to **v5.0.0** because `foundry.toml`'s `solc_version` is 0.8.20 and OZ ≥5.6 requires solc ≥0.8.22.

## What's deployed

The 7 protocol contracts + a `MockSsUSD` for tests (216 forge tests, listed under each contract in `test/`):

| Contract            | Role |
|---------------------|------|
| **OrderEscrow**     | 5-state lifecycle (Locked → Delivered/Disputed → Released/Refunded). Marketplace fee splits via `lockWithFee`. Refund-after-deadline. Operator-resolved disputes. |
| **FxOracle**        | Operator-posted FX quotes per pair, with TTL. `convert(pair, amountIn)` view helper. |
| **SetRegistry**     | Batch state-root commitments + STARK proof metadata. Strict prevStateRoot chaining. UUPS-upgradeable. |
| **SSDC**            | Rebasing T-Bill-backed stablecoin. `sweepYield()` for surplus capture above NAV. UUPS. |
| **NAVOracle**       | Posts NAV; SSDC trusts it for rebases. UUPS. |
| **SetPaymaster**    | Sequencer-gated x402 batch settlement. UUPS. |
| **SetPaymentBatch** | Auxiliary batch executor. UUPS. |
| **MockSsUSD**       | Test-only ERC20 with public `mint()` (6 decimals). Used by tests + DeployLocal. |

## Deploy locally

```bash
# anvil running on :8545
forge script script/DeployLocal.s.sol --rpc-url http://localhost:8545 --broadcast
```

The broadcast log lands at `broadcast/DeployLocal.s.sol/84532001/run-latest.json`. Bridges and demos read addresses from there automatically.

## Deploy to Sepolia

See [`script/DeploySepolia.s.sol`](./script/DeploySepolia.s.sol) and the [Sepolia runbook](../docs/DEPLOY_SEPOLIA.md) for the 7-step flow.

The `stateset deploy:sepolia` wrapper (in `../stack/stateset`) validates env vars, refuses `OWNER == deployer EOA`, and prompts for confirmation before invoking forge:

```bash
./stack/stateset deploy:sepolia
```

Required env (all 9 must be set):
- `DEPLOYER_PRIVATE_KEY` — pays gas for the deploy txs
- `OWNER_ADDRESS` — admin of upgradeable proxies (must NOT equal deployer)
- `SEQUENCER_ADDRESS` — authorized SetRegistry / SetPaymentBatch sequencer
- `ESCROW_OPERATOR_ADDRESS` — OrderEscrow operator (disputes, sweepYield)
- `FX_OPERATOR_ADDRESS` — FxOracle quote poster
- `NAV_ATTESTOR_ADDRESS` — NAVOracle initial attestor
- `TREASURY_ADDRESS` — SSDC mint authority
- `SEPOLIA_RPC_URL` — Alchemy / Infura / your node
- `ETHERSCAN_API_KEY` — for verification

For mainnet, set `USDC_ADDRESS` to the live USDC and the deploy script skips `MockSsUSD`.

## Layout note

`foundry.toml` has `src = "."`, so contracts live at the workspace root in topical subdirs (`commerce/`, `stablecoin/`) rather than under `src/`. This keeps the layout consistent with the upstream monorepo and lets deploy-script imports stay short (`../commerce/OrderEscrow.sol`).
