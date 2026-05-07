# StateSet iCommerce — Quickstart

[![CI](https://github.com/stateset/icommerce-quickstart/actions/workflows/ci.yml/badge.svg)](https://github.com/stateset/icommerce-quickstart/actions/workflows/ci.yml)
[![Latest Release](https://img.shields.io/github/v/release/stateset/icommerce-quickstart?sort=semver)](https://github.com/stateset/icommerce-quickstart/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-363636?logo=solidity)](./contracts/foundry.toml)
[![Node](https://img.shields.io/badge/Node-%E2%89%A520-339933?logo=node.js)](./bridges/package.json)

A working **local stack** of the StateSet iCommerce protocol — contracts, bridges, demos, schemas — runnable on your machine in five minutes.

> Verifiable agent commerce: a buyer's AI agent → x402 PaymentIntent → on-chain escrow → STARK-proven compliance → settlement → tamper-proof receipt. All audit-able from a cold start.

This repo is **the runnable subset**. For the full platform (sequencer, MCP tooling, admin UI), see [`stateset/icommerce-app`](https://github.com/stateset/icommerce-app).

---

## 5-minute start

Prerequisites: [Foundry](https://book.getfoundry.sh/) (`anvil`, `forge`, `cast`), Node 20+, and the [stateset-sequencer](https://github.com/stateset/stateset-sequencer) + [stateset-starks](https://github.com/stateset/stateset-starks) repos cloned with `cargo build --release` (only the latter is required for receipt verification — the sequencer is optional unless you run the agent-receipt demo).

```bash
git clone https://github.com/stateset/icommerce-quickstart && cd icommerce-quickstart

# 0. One-time: install Solidity + Node deps
bash stack/setup.sh

# 1. Bring everything up: anvil + deploy + bridges
./stack/stateset up

# 2. Watch the protocol settle a $1500 order end-to-end
./stack/stateset demo lifecycle

# 3. Verify the produced receipt independently
./stack/stateset demo verify demos/fixtures/agent-receipt.json
```

> Want to see what each command's output should look like before running? See [`docs/EXAMPLE_RUN.md`](./docs/EXAMPLE_RUN.md).

That's it. You now have a working StateSet iCommerce stack on your machine.

---

## Releases

| Tag | Date | Headline |
|---|---|---|
| **[v0.7.0](https://github.com/stateset/icommerce-quickstart/releases/tag/v0.7.0)** | 2026-05-07 | Operator surface gets serious — `show` + `audit` + `receipts` + `gates` + completion + gas baseline |
| [v0.6.0](https://github.com/stateset/icommerce-quickstart/releases/tag/v0.6.0) | 2026-05-07 | Multi-process e2e is now strict — 17 invariant assertions across both demos |
| [v0.5.0](https://github.com/stateset/icommerce-quickstart/releases/tag/v0.5.0) | 2026-05-07 | Multi-currency e2e is now a CI test — JPY→GBP cycle runs every push |
| [v0.4.0](https://github.com/stateset/icommerce-quickstart/releases/tag/v0.4.0) | 2026-05-07 | Every commerce contract under test — 216 tests (up from 93) |
| [v0.3.0](https://github.com/stateset/icommerce-quickstart/releases/tag/v0.3.0) | 2026-05-07 | Every gate gets stricter — 9 invariant assertions in e2e, schema-validation gate, `deploy:sepolia` wrapper |
| [v0.2.0](https://github.com/stateset/icommerce-quickstart/releases/tag/v0.2.0) | 2026-05-07 | Demos genuinely run in CI |
| [v0.1.0](https://github.com/stateset/icommerce-quickstart/releases/tag/v0.1.0) | 2026-05-06 | Initial release |

---

## What's in the box

| Directory | Contents |
|---|---|
| **[`contracts/`](./contracts)** | The 6 Solidity contracts (OrderEscrow, FxOracle, SetRegistry, SSDC, NAVOracle, SetPaymaster) + Foundry config + **216 tests** + deploy scripts |
| **[`bridges/`](./bridges)** | Fiat ↔ SSDC bridges. Stripe webhook on-ramp + Stripe Treasury off-ramp. **35 unit tests pass standalone** (no chain required). Multi-currency: USD/EUR/GBP/JPY/MXN |
| **[`demos/`](./demos)** | Three runnable demos:<br>• **`escrow-lifecycle`** — buyer locks, seller delivers, buyer releases (no sequencer, no STARK — just escrow)<br>• **`realmoney-loop`** — full fiat→SSDC→escrow→SSDC→fiat cycle, multi-currency<br>• **`verify-receipt`** — independent audit of any receipt |
| **[`schemas/`](./schemas)** | The 3 JSON Schemas: agent-receipt.v1, compliance-bundle.v1, cross-border-receipt.v1 |
| **[`stack/`](./stack)** | The `stateset` CLI orchestrator — single entry point for `up`, `down`, `deploy`, `demo`, `test`, `doctor` |
| **[`docs/`](./docs)** | ARCHITECTURE.md, BRIDGES.md, THREAT_MODEL.md |

---

## The escrow lifecycle demo

The simplest possible end-to-end test of the stack. ~120 lines of ethers + the deployed contracts:

```
buyer wallet ──[approve]──► SSDC
buyer wallet ──[lock]─────► OrderEscrow  (Status: Locked)
seller wallet ─[markDelivered]► OrderEscrow  (Status: Delivered)
buyer wallet ──[release]──► OrderEscrow  (Status: Released)
                                         │
                                         └──► seller receives SSDC
```

Run it:

```bash
./stack/stateset demo lifecycle
ORDER_USD=500 ./stack/stateset demo lifecycle    # custom amount
```

Output is a sequence of ✓ checkmarks with tx hashes you can paste into `cast` to inspect.

## The real-money loop demo

`bank → Stripe webhook → SSDC mint → OrderEscrow → release → SSDC pull → Stripe Treasury intent`

Single command, full multi-currency. Tokyo buyer paying JPY, London seller withdrawing GBP:

```bash
./stack/stateset demo realmoney --currency JPY --payout-currency GBP
```

The bridges talk to the on-chain `FxOracle` for both legs, so an auditor can replay the exact rate at the recorded `updatedAt`.

## The verifier demo

Three layers of independent verification — schema, on-chain, STARK:

```bash
./stack/stateset demo verify demos/fixtures/agent-receipt.json
```

No StateSet-operated server. The trust roots are: the JSON Schemas (in this repo), your RPC URL, and the open-source `ves-stark` binary (build it from [stateset-starks](https://github.com/stateset/stateset-starks)).

For Node + Python verifier libraries you can `npm install` / `pip install` into your own apps:

```bash
npm install @stateset/verify-receipt
pip install stateset-verify-receipt
```

---

## Running the tests

```bash
./stack/stateset test            # everything (needs anvil up for e2e)
./stack/stateset gates           # everything that doesn't need a chain (preview a CI push)
```

CI runs four kinds of tests on every push:

| Layer | What | Count |
|---|---|---|
| **`forge test`** in `contracts/` | OrderEscrow, FxOracle, NAVOracle, SetRegistry, SetPaymaster, SetPaymentBatch | **216** |
| **`npm test`** in `bridges/` | HMAC, secp256k1, replay rejection, multi-currency, lazy-load | **35** |
| **schema validation** (`validate-fixture.mjs`) | bundled fixture against `agent-receipt.v1.schema.json` | **1** |
| **e2e demos** (`escrow-lifecycle` + `realmoney-loop` USD + JPY→GBP) | full multi-process cycle with **17 invariant assertions** across 3 runs | **3 runs** |

Bridge tests run **standalone with no chain** — they exercise the pure verification functions (signature recovery, message canonicalization, cross-currency replay rejection).

Contract gas usage is tracked in [`contracts/.gas-snapshot`](./contracts/.gas-snapshot); regressions show as line diffs in PRs. Use `stateset bench:diff` locally to preview.

---

## What you don't get from this repo

- **Sequencer** ([stateset/stateset-sequencer](https://github.com/stateset/stateset-sequencer)) — Rust service for canonical event ordering. Build with `cargo build --release` from that repo.
- **STARK verifier binary** ([stateset/stateset-starks](https://github.com/stateset/stateset-starks)) — `ves-stark` CLI. Same drill.
- **MCP tools** — for AI agents driving the stack. Lives in the main monorepo.
- **Admin UI** — Next.js operator dashboard. Lives in the main monorepo.
- **Receipt generator** — the agent-receipt demo that mints a full STARK-proven receipt depends on the sequencer + the monorepo's sync engine. To produce real receipts, use the main `icommerce-app` repo.

This repo is the **runnable protocol layer**. The platform layer lives upstream.

---

## CLI reference

The `stateset` CLI has 21 subcommands. Tab-complete via `eval "$(stateset completion bash)"`.

```
# Lifecycle
stateset up                     anvil + deploy + bridges → ready
stateset down                   stop anvil + bridges
stateset status                 process state (what's running)
stateset show                   chain state (SSDC supply, NAV, FX freshness)

# Deploy
stateset deploy                 forge script DeployLocal --broadcast (anvil)
stateset deploy:sepolia         forge script DeploySepolia --broadcast --verify
stateset seed-fx                refresh EUR/GBP/JPY/MXN quotes

# Bridges
stateset bridges                start both bridges in the background
stateset bridges:stop           stop them

# Demos
stateset demo <name>            lifecycle | realmoney | verify
stateset audit [path]           verify-receipt against any *.json (default: bundled fixture)
stateset receipts               list every receipt-shaped JSON in the repo

# Test + bench
stateset test                   contracts + bridges + demos
stateset gates                  the 5 non-chain CI gates locally (preview a push)
stateset bench                  forge gas reports
stateset bench:snapshot         regenerate contracts/.gas-snapshot
stateset bench:diff             diff current gas vs committed snapshot

# Operator
stateset doctor [--fix]         health check; --fix auto-remediates (incl. stale FX)
stateset version                forge / node / cast versions
stateset clean                  remove cache/, out/, broadcast/, node_modules/, .run/
stateset completion <bash|zsh>  shell completion to stdout
```

Set `RPC=http://your-rpc/` to point at a different chain.

---

## Architecture in 30 seconds

```
fiat ┐                      ┌── seller bank
     │  on-ramp               │
     ▼  (Stripe webhook       ▲ off-ramp
   ┌────────┐                 │ (Stripe Treasury intent)
   │  SSDC  │  ◄── escrow ──┐ │
   └────────┘  (rebasing)   │ │
       ▲                    │ │
       │                ┌───┴─┴────┐
       │                │ Order    │
       │                │ Escrow   │
       │                └──────────┘
   ┌────────┐                ▲
   │  FX    │  ◄── reads ────┤  bridges convert non-USD
   │ Oracle │                │  amounts via the on-chain rate
   └────────┘                │
                             │
                       ┌─────┴─────┐
                       │ STARK     │  ves-stark verifier
                       │ Compliance│  3 policies:
                       │ Proofs    │   order_total.cap
                       └───────────┘   aml.threshold
                                       agent.authorization.v1
```

For the full picture: [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md).

---

## License

MIT — see [LICENSE](./LICENSE).
