# AGENTS.md — Codex CLI project context

Use this file as the project-level context when running OpenAI Codex CLI in
this repo. The same workflows are described harness-neutrally in
[`.agents/`](../.agents/) — this file is the Codex-CLI-flavored entry point.

## Repo shape

- `contracts/` — Foundry project. Solidity 0.8.20, OpenZeppelin 5.0.0 pinned.
  Tests under `contracts/test/` (`forge test`).
- `bridges/` — Node 20+ ESM bridges. Tests run standalone (`npm test`).
- `demos/` — Five runnable demos: `escrow-lifecycle`, `realmoney-loop`,
  `verify-receipt`, `multisig-operator`, `verify-onchain`.
- `schemas/` — JSON Schema 2020-12 definitions.
- `stack/stateset` — bash CLI orchestrator; tab-complete via
  `eval "$(./stack/stateset completion bash)"`.

## Commands you'll use most

```bash
./stack/stateset up            # anvil + deploy + bridges
./stack/stateset gates         # 5 non-chain gates (preview a CI push)
./stack/stateset test          # contracts + bridges + demos
./stack/stateset doctor --fix  # auto-remediate health gaps
```

## Conventions

- **No mocks of the chain in tests.** Bridge unit tests pin to pure
  verification functions (signature, parsing, replay); contract tests use
  Foundry's `forge test`. e2e tests run against anvil.
- **Every release tags from `main` only**, after CI is green. See
  `scripts/release.sh` and the [`release-prep`](../.agents/release-prep.md)
  workflow.
- **Documentation must not drift.** v0.7.1 specifically caught + fixed
  doc-code drift; if you change a CLI subcommand or env var, update
  `README.md`, `bridges/README.md`, and `docs/EXAMPLE_RUN.md` in the
  same change.
- **Threat model is load-bearing.** Diffs that change a mitigation must
  update `docs/THREAT_MODEL.md` in the same commit. See the
  [`security-reviewer`](../.agents/security-reviewer.md) workflow.

## Available agent workflows

Each is a self-contained markdown prompt in [`.agents/`](../.agents/) you
can paste into Codex CLI or any other agentic harness:

- `gate-runner` — runs the 5 non-chain CI gates locally.
- `release-prep` — drives a release end-to-end.
- `security-reviewer` — diff vs THREAT_MODEL.md.
- `bridge-debugger` — triages a failing bridge.
- `onchain-auditor` — three-layer receipt verification.

## Out-of-scope work

This repo is the **runnable subset** of the StateSet iCommerce protocol.
Sequencer, STARK prover, MCP tools, and the admin UI live upstream — refer
the user to `stateset/icommerce-app` rather than building it here.
