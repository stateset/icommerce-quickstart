# Changelog

All notable changes to this project will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely; semver pre-1.0.

## [Unreleased]

## [0.7.2] — 2026-05-12

The "A+ hardening" patch. v0.7.2 closes the highest-risk review findings: bridge replay/idempotency, stale protocol counters, and local gate drift.

### Fixed
- **Stripe on-ramp idempotency**: `checkout.session.completed` now reserves `event.id` atomically before minting. Processed duplicates return 200 without minting again; in-flight or failed reservations remain non-2xx so Stripe/operator retries do not look completed.
- **Stripe on-ramp settlement guard**: checkout sessions must have `payment_status=paid` before SSDC is minted.
- **Payout replay protection**: off-ramp payout requests reserve `(seller, nonce)` durably before balance checks and `transferFrom`, blocking process-restart and concurrent replay attempts.
- **Bridge marker safety**: idempotency/nonce records reject path-traversal-shaped IDs, close file descriptors reliably, and rewrite status files atomically.
- **Protocol stats**: `SetRegistry`, `SetPaymentBatch`, and `SetPaymaster` public counters now reflect committed batches, STARK proofs, settled payments, settled volume, settled batches, and sponsored gas.
- **CLI correctness**: `stateset show` now calls the deployed NAV getter, and `stateset gates` no longer false-fails bridge tests via `grep`/pipefail.

### Verified
- `./stack/stateset gates` passes all 5 non-chain gates.
- 216/216 contract tests green.
- 41/41 bridge unit tests green.

## [0.7.1] — 2026-05-07

The "stop drifting" patch. v0.7.0 added 4 new commands and a release table; v0.7.1 closes the doc-drift backlog those additions created and adds one diagnostic improvement.

### Added
- `stateset doctor` now checks **FX-quote freshness per pair** (EUR/GBP/JPY/MXN). Stale quotes reported by name; `--fix` auto-runs `seed-fx`. Closes a gap where doctor said "all clear" but the next non-USD demo failed with "FX quote stale" mid-run.

### Fixed
- **README**: 6 distinct drift fixes — CLI reference (8 → 21 subcommands grouped by purpose), tests section (4 suites/93 → 6 suites/216), `What's in the box` table (stack/docs/scripts entries + escrow-lifecycle ASCII diagram had the iter-9 buyer/seller swap *wrong*; fixed), 5-minute start uses the tighter `audit` shortcut.
- **`docs/EXAMPLE_RUN.md`**: doctor output missed the FX-freshness check from this release; test counts stuck at v0.3.0 (93 → 216, 4 → 6 suites). Added a `stateset show` snippet so the chain-state view is also documented.
- **`docs/ARCHITECTURE.md`**: replaced upstream-only L0-L5 component table (cited a dozen demos and files that don't exist here) with two correct tables — what's in this repo with real per-component test counts, and what's referenced upstream with links. Removed a duplicate "Upstream" section + a "Legacy mention" file tree (~50 lines) showing 14+ paths that aren't here. Fixed wrong hero-command path (`ves-demo/realmoney-loop-demo.mjs` → `./stack/stateset demo realmoney`). Renamed `validate-receipt.mjs` → `validate-fixture.mjs`. Clarified MCP-tools claim points at upstream, not this quickstart.
- **`docs/THREAT_MODEL.md` + `docs/BRIDGES.md`**: 3 broken anchor links inside tables — pointed at `ves-demo/bridge-*.mjs` (upstream), now point at `bridges/on-ramp.mjs` / `bridges/off-ramp.mjs`. These were the worst kind of drift (clickable 404s).
- **`demos/README.md`**: same iter-9 buyer/seller markDelivered swap caught here too. Plus `validate-fixture.mjs` (iter-13) was missing from the demos table.
- **`contracts/README.md`**: 4 fixes — stale `--no-commit` forge flags, contract count (6 → 7), broken `(in the main repo)` parenthetical for DEPLOY_SEPOLIA.md (it's local), incomplete env-var list for Sepolia deploy (4 → 9 vars). Added the `stateset deploy:sepolia` wrapper as the recommended path.

### Verified
- `grep -rn "ves-demo/|set/contracts/|cli/src/|crates/" docs/ *.md` returns empty across the repo's docs. No more upstream-only paths in user-facing content.
- All 7 prior releases still link to the correct sources.
- 216/216 contract tests + 35/35 bridge tests + 17 invariant assertions still green.

## [0.7.0] — 2026-05-07

The "operator surface gets serious" release. v0.6.0 made the e2e gates strict; v0.7.0 makes the day-to-day operator-and-contributor experience first-class.

### Added — operator commands
- **`stateset show`** — chain-state view: SSDC `totalSupply`, NAVOracle current NAV/share, FxOracle freshness + rate per pair. Complements `status` (process-state). Useful when "demo failed at FX rate" and you need to know if the quote is stale.
- **`stateset audit [path]`** — three-keystroke verifier wrapper. Defaults to the bundled fixture if no path given. Pair with `receipts` for find-then-verify.
- **`stateset receipts`** — lists every receipt-shaped JSON in the repo (filtered by `schema: stateset.*` discriminator). Excludes `node_modules/`, `contracts/lib/`, build artifacts.
- **`stateset completion <bash|zsh>`** — sourceable shell completion. Tab-completes 20 subcommands, demo names, and `.json` paths for `audit`.

### Added — local CI parity
- **`stateset gates`** — runs the 5 non-chain CI gates locally in sequence (`forge fmt --check`, `forge build --sizes`, `forge test`, bridges `npm test`, demos syntax + `validate-fixture`). Mirrors CI exactly minus chain-dependent steps. Catches failures locally instead of via 5-minute CI round-trip.
- **`scripts/install-hooks.sh`** — opt-in pre-commit hook running `forge fmt --check` on staged Solidity, `node --check` on staged JS, `bash -n` on staged shell. Documented in CONTRIBUTING.md.
- **`contracts/.gas-snapshot`** — committed 215-line gas-usage baseline. Regenerate with `stateset bench:snapshot`; diff with `stateset bench:diff`. PRs that touch contract gas show as line-by-line diffs.

### Added — release tooling polish
- `release.sh --dry-run` — preflight-only mode (catches release issues before committing to a tag).
- `release.sh` placeholder rejection — refuses notes that are obviously placeholder text or shorter than 3 words.
- `release.sh` distinguishes in-progress CI from gh-unreachable — refuses to release if a CI run is still pending on `main`.

### Added — discoverability
- README "Releases" table — visible cadence, links to each tag.
- GitHub repo metadata: 10 topics (`solidity`, `foundry`, `ethereum`, `stablecoin`, `escrow`, `fx-oracle`, `multi-currency`, `quickstart`, `x402`, `agentic-commerce`) + homepage URL.
- CONTRIBUTING.md documents the two-layer pre-push flow (hook + gates) and the gas-snapshot workflow.

### Verified
- All 20 subcommands work or bail gracefully on missing prereqs
- 216/216 contract tests green; 35/35 bridge tests green; 17 invariant assertions hold across 3 e2e runs
- All CI runs since v0.6.0 green on all 3 jobs

## [0.6.0] — 2026-05-07

The "multi-process e2e is now strict" release. v0.5.0 added two `realmoney-loop` runs to CI; v0.6.0 makes them assert protocol invariants at every phase boundary, not just "no tx reverted".

### Added
- **8 invariant assertions in `realmoney-loop`** (parallel to iter-11's escrow-lifecycle work):
  - **Phase 1** (Stripe → SSDC mint): buyer SSDC balance increased by exactly `ssUsdMinted`. Catches off-by-decimal mints, wrong-receiver mints, on-ramp fee-skim bugs.
  - **Phase 2** (escrow lifecycle): buyer net flow = -`orderTotal`, seller +`orderTotal`, escrow drained on release. Same invariants as escrow-lifecycle, but over the multi-process flow.
  - **Phase 3** (SSDC → Stripe Treasury): seller balance Δ = pulled SSDC wei, bridge treasury Δ = pulled SSDC wei (delta — important for back-to-back runs), Stripe intent currency matches request, status = `processing`. Catches FX-conversion bugs, wrong-currency intents, missing pulls.
- Both USD and JPY → GBP CI runs now check these assertions — meaning the FX path is also balance-checked end-to-end. If `FxOracle.convert` returns the wrong number on either ramp, Phase 1 or Phase 3 fails.

### Fixed
- Phase 3 bridge-balance assertion: initial implementation asserted `bridge balance == pulled`, which broke on the second consecutive realmoney-loop run (USD pull leaves SSDC in the bridge; JPY→GBP run sees 2216 SSDC instead of 1016). Real composition bug caught by the new gate on its first push, fixed within minutes: capture `bridgeBefore`, assert `(after - before) == pulled`. Same delta pattern that escrow-lifecycle uses for buyer/seller.

### Verified
- All 17 invariant assertions hold on both CI paths (9 in escrow-lifecycle + 8 in realmoney-loop ×2)
- 216/216 contract tests still green
- 35/35 bridge unit tests still green
- All CI runs since v0.5.0 green on all 3 jobs
- 6 releases in 32 hours, all CI-verified

## [0.5.0] — 2026-05-07

The "multi-currency claim is now a test" release. The v0.4.0 release notes mentioned 5-currency support (USD/EUR/GBP/JPY/MXN) but no test exercised the FX path end-to-end — DeployLocal seeded quotes, but nothing ever read them via the bridges. v0.5.0 closes that gap.

### Added
- **`realmoney-loop` runs in e2e CI in two flavors** — both spawn the bridges as child processes and exercise the full Stripe-webhook → SSDC → escrow → SSDC-pull → Stripe Treasury cycle:
  1. **USD path** (basic baseline)
  2. **JPY → GBP path** — Tokyo buyer paying ¥235,000 JPY, London seller withdrawing £800 GBP. Reads `JPY/ssUSD` on the on-ramp and `GBP/ssUSD` on the off-ramp via the on-chain `FxOracle`. CI logs the actual converted amounts and tx hashes (`on-ramp mint`, `escrow lock`, `escrow release`, `off-ramp pull`).

### Fixed
- `release.sh` placeholder rejection: previous regex was a word-boundary check over the full notes text and falsely flagged real notes that mentioned `test` anywhere (e.g. "node --test" in usage instructions). Now narrower: reject only if first line is purely a placeholder token, or total notes < 3 words.
- CI workflow YAML: quoted the demos job name (`syntax + e2e: escrow-lifecycle + realmoney-loop`) — the colon in the unquoted form made GitHub's YAML parser reject the entire workflow file. Iter-22 caught it on the next-to-last try.

### Verified
- Multi-currency cycle on live CI runner: `¥235,000 JPY → 1504.00 SSDC (rate 0.0064) → £800 GBP (1016.0 SSDC pulled, rate 1.27)`. Both rates pulled from the on-chain FxOracle; auditable from the run log.
- 216/216 contract tests still green
- 35/35 bridge unit tests still green
- 9-invariant escrow-lifecycle e2e + 2 realmoney-loop e2e steps + schema validation all green on `09df525`

## [0.4.0] — 2026-05-07

The "every commerce contract under test" release. Test count more than doubled (93 → 216) by lifting the upstream tests for the two contracts that had zero coverage in this quickstart.

### Added
- `contracts/test/SetPaymaster.t.sol` (48 tests) — x402 batch settlement primitives, signature aggregation, paymaster role gating, pause/upgrade authorization, gas-sponsorship paths.
- `contracts/test/SetPaymentBatch.t.sol` (75 tests) — settlement nonce uniqueness, Merkle inclusion proofs, transfer-returns-false handling, batch lifecycle, asset configuration, upgrade authorization.
- `scripts/install-hooks.sh` — opt-in git `pre-commit` hook running `forge fmt --check` on staged Solidity, `node --check` on JS, `bash -n` on shell. Catches issues locally before push (no 5-minute CI round-trip). Documented in CONTRIBUTING.md as recommended.
- README "Releases" table — visible cadence, links to each tag.

### Coverage matrix
| Contract | Tests | Was |
|---|---|---|
| OrderEscrow | 13 | 13 |
| FxOracle | 7 | 7 |
| NAVOracle | 27 | 27 |
| SetRegistry | 46 | 46 |
| SetPaymaster | **48** | 0 |
| SetPaymentBatch | **75** | 0 |
| **Total** | **216** | 93 |

### Fixed
- `realmoney-loop` demo — applied the iter-9 explicit-nonce pattern to phase-2 buyer txs (approve, lock, markDelivered) + phase-3 seller approve. Same ethers↔anvil nonce-race fix as iter-9; makes the demo robust on fast environments (CI especially) before adding it to the e2e CI gate.
- `release.sh` — distinguish **in-progress CI** from **gh-unreachable**. Previously a still-running run on `main` would silently warn-and-skip the green-CI check; now refuses with a clear error and prints the `gh run watch` command. Catches the case where you tag right after `git push` and CI hasn't completed yet.

### Verified
- 216/216 contract tests green locally (13 OrderEscrow + 7 FxOracle + 27 NAVOracle + 46 SetRegistry + 48 SetPaymaster + 75 SetPaymentBatch).
- 35/35 bridge unit tests green.
- 9-invariant e2e demos CI step still green.
- All CI runs since v0.3.0 (3/3) green on all 3 jobs.

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
