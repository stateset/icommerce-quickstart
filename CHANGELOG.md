# Changelog

All notable changes to this project will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely; semver pre-1.0.

## [Unreleased]

### Added
- `contracts/test/SetPaymaster.t.sol` (48 tests) — covers x402 batch settlement primitives, signature aggregation, paymaster role gating, pause/upgrade authorization, and gas-sponsorship paths.
- `contracts/test/SetPaymentBatch.t.sol` (75 tests) — covers settlement nonce uniqueness, Merkle inclusion proofs, transfer-returns-false handling, batch lifecycle, asset configuration, and upgrade authorization.
- **Test count: 93 → 216** (+123, ~2.3× growth). All pass locally; CI verifies on this push.

### Fixed
- `realmoney-loop` demo — applied the iter-9 explicit-nonce pattern to phase-2 buyer txs (approve, lock, markDelivered) + phase-3 seller approve. Without this, the same ethers↔anvil nonce race that bit `escrow-lifecycle` in CI can hit anyone running this demo on a fast environment (especially CI). Same fix as iter-9: fetch nonce from chain at phase start, pass `nonce: ...` explicitly on every tx.
- `release.sh`: distinguish **in-progress CI** from **gh-unreachable**. Previously a still-running CI run on `main` would silently warn-and-skip the green-CI check; now it refuses with a clear error and prints the `gh run watch` command to wait. Catches the case where you tag right after a push and the CI run hasn't completed yet.

### Added
- README "Releases" table — visible release cadence, links to each tag.

## [0.3.0] — 2026-05-07

The "every gate gets stricter" release. Builds on the v0.2.0 e2e gate by making it actually rigorous (9 invariant assertions), adds a fast schema-validation gate, makes testnet deploy operator-friendly, and hardens the release flow against the trap that bit me shipping v0.2.0.

### Added
- **`escrow-lifecycle` demo: 9 invariant assertions** at every state transition. After `lock`: buyer balance dropped by exactly `amount`, escrow holds exactly `amount`, status=Locked. After `markDelivered`: escrow still holds `amount`, status=Delivered. After `release`: escrow drained, seller received `amount`, buyer net flow = -`amount`, status=Released. The e2e CI step now catches contract bugs that don't revert but produce wrong balances — a class of failure that lock-success + release-success alone could miss (fee-skim mistakes, off-by-one in amount, double-mint, drain on the wrong transition).
- `demos/validate-fixture.mjs` — JSON Schema 2020-12 validation of receipts. Runs in CI as a fast (~10ms) gate before the slow e2e path. Catches schema↔fixture drift the moment it lands in a PR. Bundled fixture validates green.
- `stateset deploy:sepolia` — production-shape testnet/mainnet deploy wrapper. Validates 9 required env vars, refuses to proceed if `OWNER_ADDRESS == deployer EOA` (production safety: upgrade authority must NOT equal deploying key), prints the role-assignment table, prompts for `deploy` confirmation, then runs `forge script DeploySepolia --broadcast --verify`.
- `docs/DEPLOY_SEPOLIA.md` — 7-step runbook: env setup → verify-via-wrapper → deploy → hand off ownership to multi-sig (deliberately separate step 4, not step 3) → seed FX → smoke-test against Sepolia → tag the deploy. Plus a "What this doesn't do" section calling out sequencer/bridge/treasury concerns as separate.
- `docs/EXAMPLE_RUN.md` — markdown transcript of expected output for each `stateset` command. Visual proof a visitor can verify against their local run on github.com without cloning. Linked from README's quick-start.
- `release.sh --dry-run` — runs preflight only (clean tree, on-main, in-sync, tag-novel, CHANGELOG entry, CI green) without tagging/pushing/releasing. Verify preflight before committing to release.
- `release.sh` rejects obvious placeholder notes (`test`, `wip`, `tbd`, `dry-run`, `draft`, etc.) and notes shorter than 3 words. Pass real notes, or use `--dry-run`.

### Verified
- 93/93 contract tests green
- 35/35 bridge unit tests green (no chain required)
- 9-invariant e2e demos CI step (anvil → forge install → deploy → run `escrow-lifecycle.mjs`) green at [`6981972`](https://github.com/stateset/icommerce-quickstart/commit/6981972) and at every push since
- Schema-validation gate green on bundled fixture
- All CI runs since v0.2.0 (4/4) green on all 3 jobs

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
