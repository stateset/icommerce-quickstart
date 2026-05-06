# Security policy

This repo is the **runnable subset** of the StateSet iCommerce protocol — Solidity contracts, fiat ↔ SSDC bridges, and demos. Vulnerabilities here have a real blast radius (locked funds, replay-able payouts, on-chain authorization bypass) so we treat them seriously.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security findings.**

Two channels:

1. **GitHub Security Advisories (preferred).** From the repo's [Security tab → Report a vulnerability](https://github.com/stateset/icommerce-quickstart/security/advisories/new). Lets us discuss, ship a private fix branch, and coordinate disclosure without leaking the bug to scanners.

2. **Email.** `security@stateset.com` for findings that don't fit the GitHub flow.

Please include:

- The vulnerable code path (file + line + commit hash)
- A proof-of-concept or repro steps
- The impact (what an attacker gains, what's at risk)
- Whether you intend to disclose (and on what timeline)

We aim to acknowledge within 72 hours.

## Scope

### In scope

- **Solidity contracts** in [`contracts/`](./contracts) — OrderEscrow, FxOracle, SetRegistry, SSDC, NAVOracle, SetPaymaster, SetPaymentBatch.
- **Bridges** in [`bridges/`](./bridges) — HMAC verification on the on-ramp, secp256k1 signature + replay protection on the off-ramp, FxOracle reads.
- **Demos and verifiers** — only the parts that consume receipts cryptographically (`verify-receipt.mjs`, `audit-with-cast.sh`).
- **`stack/stateset`** — only operational hardening (e.g. command injection, path traversal). The CLI doesn't hold keys.

### Out of scope (file upstream)

- **Sequencer** — file at [`stateset/stateset-sequencer`](https://github.com/stateset/stateset-sequencer/security/advisories/new).
- **`ves-stark` verifier binary** — file at [`stateset/stateset-starks`](https://github.com/stateset/stateset-starks/security/advisories/new).
- **MCP tools, admin UI, sync engine** — file at [`stateset/icommerce-app`](https://github.com/stateset/icommerce-app/security/advisories/new).

### Out of scope here (always)

- Findings in third-party dependencies — file with the dependency upstream first; if there's a workaround we should ship in this repo, file here too.
- Spam, brute-force without a vulnerability, social engineering of contributors.
- Vulnerabilities only exploitable by someone who already controls the operator key — that's a trust assumption, not a bug. Document additional defenses for those in [`docs/THREAT_MODEL.md`](./docs/THREAT_MODEL.md).

## Disclosure timeline

- Day 0: report received
- Day ≤3: triage acknowledgement
- Day ≤14: severity assessment + fix plan shared with reporter
- Day ≤90: public advisory + patch released; credit reporter unless they prefer otherwise

We can extend the 90-day clock for genuinely-hard fixes if the reporter agrees.

## Supported versions

Pre-1.0 — only the `main` branch and the latest tagged release. Older tags will not receive security backports.

## Security-relevant context

- **OpenZeppelin pinned to v5.0.0** ([`contracts/foundry.toml`](./contracts/foundry.toml)). We don't auto-bump because newer OZ versions require a newer solc that hasn't been audited against our contracts yet.
- **The bridges hold operator keys** in env vars. In production deploys, use a real KMS / hardware wallet, not the demo's anvil-default keys.
- **Cross-chain replay is bound by `chainId` in signed messages**; cross-currency replay is bound by `outputCurrency`. Both are unit-tested. See [`docs/THREAT_MODEL.md`](./docs/THREAT_MODEL.md).
