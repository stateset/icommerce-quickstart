# Changelog

All notable changes to this project will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely; semver pre-1.0.

## [Unreleased]

### Added
- `.github/ISSUE_TEMPLATE/` — structured bug-report + feature-request forms; the bug form prompts for `./stack/stateset doctor` output up front.
- `.github/PULL_REQUEST_TEMPLATE.md` — checklist (test plan, CHANGELOG update, scope check).
- `.github/dependabot.yml` — weekly npm + GitHub Actions dependency updates.
- CI workflow now supports `workflow_dispatch` — re-run any time from the Actions tab without pushing.
- `contracts/test/NAVOracle.t.sol` — 27 tests covering attestor authorization, NAV staleness, history bounds, and SSDC integration. Verified locally: **27/27 passing**.
- `stack/setup.sh` — one-shot first-time setup (forge install + npm install for bridges + demos). Idempotent.
- `stateset version` subcommand — prints CLI version + paths + versions of forge / node / cast.
- `stateset doctor` now checks tooling (forge, node, cast), Solidity dependencies (forge-std, openzeppelin), schemas, and `STARK_BIN` before runtime checks.
- `contracts/test/SetRegistry.t.sol` — adds coverage for prevStateRoot chaining, batch commit/finalize, STARK proof metadata. CI green at `0725129`.
- README badges — CI status, latest release, license, Solidity version, Node version. Visible signal of "this works" at a glance.

### Changed
- README's 5-minute start now includes `bash stack/setup.sh` as a one-time step — so the repo is genuinely runnable from a fresh clone.

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
