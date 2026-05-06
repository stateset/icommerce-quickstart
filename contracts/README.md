# contracts — StateSet iCommerce Solidity workspace

The on-chain protocol layer. Foundry-shape: `foundry.toml` at the workspace root, contracts in `commerce/` + `stablecoin/` + `SetRegistry.sol`, deploy scripts in `script/`, tests in `test/`.

## Setup

```bash
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/openzeppelin-contracts@v5.0.0 --no-commit
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.0.0 --no-commit
forge build
forge test
```

`lib/` is gitignored (standard Foundry pattern); these `forge install` commands populate it. Pin OpenZeppelin to **v5.0.0** because the foundry.toml `solc_version` is 0.8.20 and OZ ≥5.6 requires solc ≥0.8.22.

## What's deployed

The 6 commerce contracts + a `MockSsUSD` for tests:

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

See [`script/DeploySepolia.s.sol`](./script/DeploySepolia.s.sol) and `../docs/DEPLOY_SEPOLIA.md` (in the main repo).

```bash
forge script script/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

Required env: `DEPLOYER_PRIVATE_KEY`, `OWNER_ADDRESS` (must differ from deployer), `SEPOLIA_RPC_URL`, `ETHERSCAN_API_KEY`.

## Layout note

`foundry.toml` has `src = "."`, so contracts live at the workspace root in topical subdirs (`commerce/`, `stablecoin/`) rather than under `src/`. This keeps the layout consistent with the upstream monorepo and lets deploy-script imports stay short (`../commerce/OrderEscrow.sol`).
