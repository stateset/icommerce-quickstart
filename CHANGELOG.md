# Changelog

All notable changes to this project will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) loosely; semver pre-1.0.

## [Unreleased]

### Added
- Initial repo: contracts, bridges, demos, schemas, `stack/stateset` CLI orchestrator, docs
- 6 Solidity contracts (OrderEscrow, FxOracle, SetRegistry, SSDC, NAVOracle, SetPaymaster) + Foundry config + Sepolia deploy script
- Multi-currency fiat ↔ SSDC bridges (USD/EUR/GBP/JPY/MXN) with HMAC + secp256k1 + cross-chain replay rejection
- 3 runnable demos: `escrow-lifecycle`, `realmoney-loop`, `verify-receipt`
- Bundled fixture receipt for offline verification
- 3 JSON Schemas (agent-receipt, compliance-bundle, cross-border-receipt)
- `stack/stateset` CLI with `up | down | deploy | bridges | demo | test | doctor | seed-fx`
- CI workflow gating contracts (forge build + test), bridges (node --test), demos (syntax check)
- Per-directory READMEs

### Verified
- `forge build` clean, `forge test` 20/20 passing (13 OrderEscrow + 7 FxOracle)
- `npm test` in bridges 35/35 passing (HMAC + signature + replay + multi-currency, no chain required)
- `node --check` clean across all demos
- `bash -n` clean on `stack/stateset` and `audit-with-cast.sh`

### What's not in (deliberately, see README)
- Sequencer (lives in `stateset/stateset-sequencer`)
- `ves-stark` CLI (lives in `stateset/stateset-starks`)
- MCP tools, admin UI, sync engine (live in `stateset/icommerce-app` monorepo)
- Receipt-producer (depends on the sequencer + sync engine; this repo verifies, doesn't produce)
