# Changelog

All notable changes to this project will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely; semver pre-1.0.

## [Unreleased]

### Added
- `stateset deploy:sepolia` — production-shape testnet/mainnet deploy wrapper. Validates every required env var (DEPLOYER_PRIVATE_KEY, OWNER_ADDRESS, SEQUENCER_ADDRESS, ESCROW_OPERATOR_ADDRESS, FX_OPERATOR_ADDRESS, NAV_ATTESTOR_ADDRESS, TREASURY_ADDRESS, SEPOLIA_RPC_URL, ETHERSCAN_API_KEY); refuses to proceed if `OWNER_ADDRESS == deployer EOA` (production safety: upgrade authority must not equal deploying key); prints the full role assignment and prompts for `deploy` confirmation before running.
- `docs/DEPLOY_SEPOLIA.md` — 7-step runbook covering env setup, confirmation, ownership-transfer to multi-sig (Step 4), FX seeding, smoke-test against Sepolia, deploy tagging, plus what the wrapper deliberately doesn't do (sequencer setup, bridge hosting, treasury-vault contract, NAV seeding).
- `demos/validate-fixture.mjs` — JSON Schema 2020-12 validation of receipts against the schemas in this repo. Runs in CI as a fast gate (~10ms) so schema↔fixture drift is caught before the slow e2e path. Bundled fixture validates green.
- `docs/EXAMPLE_RUN.md` — markdown transcript of the expected output for each `stateset` command (`up`, `demo lifecycle`, `doctor`, `test`, `demo realmoney`). Real "this works" signal a visitor can verify against their local run, without needing screen-recording infra. Closes the iter-7 grade item about visual proof. Linked from README's quick-start.
- `release.sh --dry-run` — runs preflight only, no tag/push/release. Closes the v0.2.0-shipping-with-placeholder-notes ergonomic trap.
- `release.sh` now rejects obvious placeholder notes (`test`, `wip`, `tbd`, `dry-run`, etc., or fewer than 3 words). Pass real notes, or use `--dry-run` to verify preflight.
- **`escrow-lifecycle` demo: 9 invariant assertions** at every state transition. Asserts buyer balance dropped by exactly `amount`, escrow received exactly `amount`, status=Locked. Asserts escrow still holds `amount` after `markDelivered`, status=Delivered. Asserts escrow drained, seller received `amount`, buyer net flow = `amount`, status=Released. The e2e CI step now catches contract bugs that don't revert but produce wrong balances — a class of failure `node --check` and even basic e2e couldn't catch before.

## [0.2.0] — 2026-05-07

The "demos genuinely run in CI" release. Closes every iter-7 self-grade item that didn't require a clean VM.

### Added
- **CI demos job now runs `escrow-lifecycle.mjs` end-to-end** against an in-CI anvil + freshly-deployed contracts. Catches ABI drift, ethers signature changes, contract revert paths, address-discovery bugs that `node --check` cannot. The biggest reliability win from this release.
- `forge fmt --check` and `forge build --sizes` in the contracts CI job — catches unformatted contracts and surfaces contract-size growth in CI logs.
- `scripts/release.sh` — automates tag → push → GitHub-release flow. Validates clean tree, on-`main`, in-sync, tag-doesn't-exist, CHANGELOG entry, latest CI green. `--force` to skip the soft checks.
- `stack/setup.sh` — one-shot first-time setup (forge install + npm install for bridges + demos). Idempotent.
- New `stateset` subcommands: **`bench`** (gas-report wrapper), **`clean`** (artifact cleanup with `--all`), **`version`** (versions of forge/node/cast).
- `stateset doctor` now checks tooling (forge, node, cast), Solidity deps (forge-std, openzeppelin), schemas, `STARK_BIN`.
- `SECURITY.md` — full disclosure policy. GitHub Security Advisories preferred, scope split (this repo vs upstream sequencer/STARK/monorepo), 90-day disclosure clock.
- `CODE_OF_CONDUCT.md` — Contributor Covenant 2.1.
- `.github/CODEOWNERS` — auto-routes review.
- `.github/ISSUE_TEMPLATE/` — structured bug-report + feature-request forms; bug form prompts for `./stack/stateset doctor` output.
- `.github/PULL_REQUEST_TEMPLATE.md` — checklist (test plan, CHANGELOG, scope).
- `.github/dependabot.yml` — weekly npm + GitHub Actions dependency updates. Already merged 2 PRs (`actions/checkout` v4→v6, `actions/setup-node` v4→v6).
- CI workflow `workflow_dispatch` trigger — re-run from the Actions tab without pushing.
- README badges — CI status, latest release, license, Solidity, Node.
- `contracts/test/SetRegistry.t.sol` (~1158 lines, 46 tests) — covers strict prevStateRoot chaining, batch commit/finalize, STARK proof metadata.
- `contracts/test/NAVOracle.t.sol` (27 tests) — attestor authorization + revocation, NAV update sanity bounds, staleness/history bounds, SSDC integration.

### Fixed
- **`escrow-lifecycle` demo** — caught and fixed by the new e2e CI gate on its first two runs:
  1. `NONCE_EXPIRED` race on the lock tx — fetch nonces from chain at script start and pass `nonce: ...` explicitly on every tx; removes the ethers↔anvil race in CI environments.
  2. `markDelivered` was called from the seller wallet, but `OrderEscrow.markDelivered` requires `msg.sender == buyer || operator` (recipient confirms delivery, not sender — correct escrow semantics). Now buyer calls `markDelivered`, then seller calls `release`. `confirmationWindow` set to 0 since no dispute window is needed when buyer attests directly.
- `contracts/` — `forge fmt` reformatted 16 files (777+/852-, all cosmetic). 93 tests still pass.
- `docs/ARCHITECTURE.md` and `docs/THREAT_MODEL.md` — replaced monorepo-only paths (`set/contracts/`, `ves-demo/`) with this repo's paths. Architecture doc now also enumerates the upstream repos.

### Changed
- README's 5-minute start now includes `bash stack/setup.sh` as a one-time step. Test counts updated (47+ → 93).

### Verified
- **93 contract tests** pass (13 OrderEscrow + 7 FxOracle + 27 NAVOracle + 46 SetRegistry).
- **35 bridge unit tests** pass (HMAC + signature + replay + multi-currency, no chain required).
- **e2e demos CI step** (anvil boot → forge install → deploy → run `escrow-lifecycle.mjs`) green at [`357c5ef`](https://github.com/stateset/icommerce-quickstart/commit/357c5ef).
- All 3 CI jobs green on `main` at release time.

## [0.1.0] — 2026-05-06

Initial public release. CI green at [`0725129`](https://github.com/stateset/icommerce-quickstart/commit/0725129); release at [`releases/tag/v0.1.0`](https://github.com/stateset/icommerce-quickstart/releases/tag/v0.1.0).

### Added
- Repo scaffold: `contracts/`, `bridges/`, `demos/`, `schemas/`, `stack/`, `docs/`, top-level READMEs.
- 6 Solidity contracts (OrderEscrow, FxOracle, SetRegistry, SSDC, NAVOracle, SetPaymaster) + `MockSsUSD` + Foundry config + `DeployLocal` + `DeploySepolia`.
- Fiat ↔ SSDC bridges with multi-currency support (USD/EUR/GBP/JPY/MXN) — HMAC verification on the on-ramp, secp256k1-signed payout requests on the off-ramp, cross-chain + cross-currency replay rejection bound into the canonical message.
- Three runnable demos: `escrow-lifecycle` (~120-line ethers-only), `realmoney-loop` (full multi-currency cycle), `verify-receipt` (independent audit). Plus `audit-with-cast.sh` (pure shell + jq + cast).
- Three JSON Schemas: agent-receipt.v1, compliance-bundle.v1, cross-border-receipt.v1.
- `stack/stateset` CLI: `up | down | deploy | bridges | demo | test | doctor | seed-fx`.
- CI workflow with three jobs (contracts, bridges, demos).
- `CONTRIBUTING.md` documenting in-scope vs upstream-monorepo work.

### Verified
- `forge build` + `forge test` 20/20 passing (13 OrderEscrow + 7 FxOracle).
- `npm test` in `bridges/` 35/35 passing (HMAC + signature + replay + multi-currency, no chain required).
- `node --check` clean across all demos.
- `bash -n` clean on `stack/stateset` and `audit-with-cast.sh`.
- CI green on contracts + bridges + demos jobs.

### Not in this repo (by design)
- **Sequencer** — Rust service; lives in [`stateset/stateset-sequencer`](https://github.com/stateset/stateset-sequencer).
- **`ves-stark` CLI** — Winterfell verifier; lives in [`stateset/stateset-starks`](https://github.com/stateset/stateset-starks).
- **MCP tools, admin UI, sync engine** — live in the [`stateset/icommerce-app`](https://github.com/stateset/icommerce-app) monorepo.
- **Receipt-producer** — depends on the sequencer + sync engine; this repo verifies, doesn't produce.
