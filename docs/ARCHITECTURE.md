# StateSet Architecture

The view a technical evaluator wants after they've read [THESIS.md](../THESIS.md): components, data flow, trust boundaries, failure modes. Everything in this doc traces back to a runnable demo.

## High-level data flow — the real-money loop

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │                        REAL-MONEY LOOP                                │
   │                                                                      │
   │   ┌─ FIAT IN ─────────────────────────────────────────────────────┐  │
   │   │                                                               │  │
   │   │     BUYER BANK ─────► Stripe Checkout ─────► webhook         │  │
   │   │                                                  │            │  │
   │   │                                                  ▼            │  │
   │   │                  ┌──────────────────────────────────┐         │  │
   │   │                  │  bridge-stripe-to-ssdc.mjs        │         │  │
   │   │                  │  • verifies HMAC sig (Stripe v1)  │         │  │
   │   │                  │  • parses checkout.session.…       │         │  │
   │   │                  │  • SSDC.mintShares(buyer, amount) │         │  │
   │   │                  └────────────┬─────────────────────┘         │  │
   │   └─────────────────────────────── │ ────────────────────────────  ┘  │
   │                                    ▼                                  │
   │   ┌─ ON-CHAIN COMMERCE ────────────────────────────────────────────┐  │
   │   │                                                                │  │
   │   │   BUYER WALLET (SSDC)                                          │  │
   │   │      │                                                         │  │
   │   │      │ approve(escrow) + lock[WithFee]                         │  │
   │   │      ▼                                                         │  │
   │   │   ┌──────────────────────────────────────────┐                 │  │
   │   │   │  OrderEscrow                              │                 │  │
   │   │   │  • Locked → Delivered → Released           │                 │  │
   │   │   │            ↓                              │                 │  │
   │   │   │          Disputed → operator.resolve       │                 │  │
   │   │   │            ↓                              │                 │  │
   │   │   │       deadline → Refunded                 │                 │  │
   │   │   │  • marketplace fee (BPS, ≤10%) atomic      │                 │  │
   │   │   │  • sweepYield (rebasing surplus)          │                 │  │
   │   │   └────────┬─────────────────────────────────┘                 │  │
   │   │            │                                                   │  │
   │   │   ┌────────▼─────────┐    ┌──────────────┐    ┌──────────────┐ │  │
   │   │   │  SSDC (rebasing) │    │  FxOracle     │    │  SetRegistry │ │  │
   │   │   │  + NAVOracle     │    │  (TTL quotes) │    │  + STARK ref │ │  │
   │   │   └──────────────────┘    └──────────────┘    └──────────────┘ │  │
   │   │            │                                          ▲        │  │
   │   │            │                                          │        │  │
   │   │            │                ┌──────────────┐    ves-stark CLI  │  │
   │   │            │                │ stateset-    │     (Winterfell)  │  │
   │   │            │                │ sequencer    │                    │  │
   │   │            │                │ (VES + x402)  │                    │  │
   │   │            │                └──────────────┘                    │  │
   │   │            ▼                                                    │  │
   │   │   SELLER WALLET (SSDC)                                         │  │
   │   │                                                                │  │
   │   └────────────────────────────────────────────────────────────────┘  │
   │                                    │                                  │
   │                                    │ approve + signed payout request  │
   │                                    ▼                                  │
   │   ┌─ FIAT OUT ────────────────────────────────────────────────────┐  │
   │   │                                                               │  │
   │   │                  ┌──────────────────────────────────┐         │  │
   │   │                  │  bridge-ssdc-payout.mjs           │         │  │
   │   │                  │  • verifies secp256k1 signature   │         │  │
   │   │                  │  • SSDC.transferFrom → treasury   │         │  │
   │   │                  │  • returns Stripe Treasury intent  │         │  │
   │   │                  └────────────┬─────────────────────┘         │  │
   │   │                               ▼                               │  │
   │   │                   Stripe Treasury OutboundPayment             │  │
   │   │                               ▼                               │  │
   │   │                          SELLER BANK (T+1 ACH)                │  │
   │   └───────────────────────────────────────────────────────────────┘  │
   │                                                                      │
   └──────────────────────────────────────────────────────────────────────┘
```

Run the entire loop in one command: `node ves-demo/realmoney-loop-demo.mjs`.

## Component map

| Layer | Component | Implementation | Demo |
|-------|-----------|----------------|------|
| **L0** | Set Chain L2 (Anvil locally) | OP Stack devnet config in `set/` | `setup.sh` brings it up |
| **L1** | `SetRegistry` | UUPS proxy, anchors batch root + STARK proof | every demo emits via `commitBatchWithStarkProof` |
| **L1** | `SetPaymentBatch` | UUPS proxy, x402 batch settlement | not used in current demos (alt path) |
| **L1** | `SetPaymaster` | UUPS proxy, gas sponsorship | not used in current demos |
| **L1** | `OrderEscrow` | Plain contract, 13/13 tests pass | every commerce demo |
| **L1** | `FxOracle` | Plain contract, 7/7 tests pass | `cross-border-demo.mjs` |
| **L1** | `SSDC` (+ `NAVOracle`) | Production rebasing stablecoin | `production-ssdc-demo.mjs`, `yield-rebasing-demo.mjs` |
| **L1** | `MockSsUSD` | 6dp test ERC-20 | `agent-receipt.mjs` (legacy path) |
| **L2** | `stateset-sequencer` | Rust, Axum + Postgres, VES events + x402 | every agent-receipt demo |
| **L2** | `set-anchor` | Rust, polls sequencer → SetRegistry | currently disabled (auth bug); demos drive synchronously |
| **L3** | `ves-stark` CLI | Rust, Winterfell prover/verifier | `compliance-bundle-demo.mjs`, `verify-receipt.mjs` |
| **L4** | Stripe bridges (on/off-ramp) | Node, plain `node:http` | `bridge-stripe-to-ssdc.mjs` + `bridge-ssdc-payout.mjs` |
| **L5** | MCP tools (11) | JS, registered in `cli/src/tools/agent-receipt.js` | every Claude scenario |
| **L5** | CLI / dashboard / CSV export | Bash + static HTML + Node | `bin/stateset`, `dashboard/index.html`, `export-statement-csv.mjs` |

## Trust boundaries

Each boundary lists the cryptographic primitive that protects it.

```
┌─────────────────┐  HMAC-SHA256 over `${t}.${body}`  ┌─────────────────┐
│  Stripe         │ ──── Stripe-Signature header ─────►│  on-ramp bridge │
│  (or any        │      (5-min timestamp tolerance)   │                 │
│  webhook source)│                                    │                 │
└─────────────────┘                                    └────────┬────────┘
                                                                │
                                                                │ treasury key
                                                                │ (operator wallet)
                                                                ▼
                              ┌───────────────────────────────────────────┐
                              │  SSDC.mintShares()                          │
                              │  onlyTreasury — only the configured wallet  │
                              │  can mint into existence                    │
                              └────────────────────┬──────────────────────┘
                                                   │
                                                   │ buyer's secp256k1 (EOA wallet)
                                                   │ — never touches the platform
                                                   ▼
              buyer signs:  approve() + lock()/lockWithFee()
              ↓
              OrderEscrow holds funds ── only buyer | seller | operator can mutate
              ↓
              VES events Ed25519-signed by originating agent (per-event proof)
              ↓
              Sequencer assigns canonical seq + Merkle root
              ↓
              SetRegistry.commitBatchWithStarkProof
              ↓ — only authorizedSequencer
              ┌──────────────────────────────────────────────┐
              │  STARK proof (Winterfell)                     │
              │  • order_total.cap     amount ≤ cap            │
              │  • aml.threshold       amount < AML_threshold  │
              │  • agent.authorization amount ≤ delegated max  │
              └──────────────────────────────────────────────┘
              ↓
              seller.release()  → SSDC.transferFrom (escrow → seller)
              ↓
              seller signs canonical payout message (secp256k1)
              ↓
              off-ramp bridge verifies signature → SSDC.transferFrom (seller → treasury)
              ↓
              Stripe Treasury OutboundPayment.create
              ↓
              ACH wire → seller bank (T+1)
```

Every transition is either an on-chain transaction (verifiable via `cast`/RPC) or a signed off-chain message (verifiable via `verifyMessage` / HMAC). There is no "and then trust this server."

## Failure modes (and what catches them)

| Failure | Detection | Response |
|---------|-----------|----------|
| Buyer's card chargeback after Stripe webhook | Off-protocol — Stripe handles via dispute API | Burn equivalent SSDC out of buyer wallet (hard — requires balance freeze; current design treats this as residual risk to be handled at the bridge layer) |
| Stripe webhook signature replay | `verifyStripeSignature` 5-min timestamp tolerance + body-binding | Bridge rejects with 400 |
| Bridge operator key compromise | Mint privilege limited to one address; rotate via SSDC.setTreasuryVault | Multi-sig the treasury wallet in production |
| Seller pulls funds twice via different orders | `OrderEscrow.totalLocked` accounting per-token; `release()` decrements | Math is checked; balance can't double-spend |
| Buyer fakes a delivery receipt to grab funds | `markDelivered` is buyer-only; `release()` requires status==Delivered | Buyer attesting delivery is the prerequisite — no off-platform proof needed |
| Seller never ships (reneges) | `deliveryDeadline` + `refund()` callable by buyer after deadline | `refund-timeout-demo.mjs` |
| Operator (sequencer) falsifies a STARK proof commitment | Anyone can re-run `ves-stark verify` against the canonical proof file | `verify-receipt.mjs` + `audit-with-cast.sh` |
| FxOracle stale quote (rate moved before commit) | `convert()` reverts with `StaleQuote` past TTL | Demo handles by failing the transaction; production: re-quote |
| Receipt drift (snapshot vs current chain) | `verify-receipt.mjs` flags as "drifted" rather than "failed" | Operator-visible signal; cryptographic claims unaffected |
| Replay of a payout request | `usedNonces[seller][nonce]` map in bridge | 400 on second submit |
| Compromised seller wallet | Out of scope at protocol layer; same risk as any EOA | Multi-sig; hardware wallet; key-management ops |

## Operational layout

### In this repo (`icommerce-quickstart`)

```
icommerce-quickstart/
├── contracts/             Solidity (Foundry, OpenZeppelin v5.0.0)
│   ├── SetRegistry.sol                  ← state-root + STARK metadata
│   ├── commerce/
│   │   ├── OrderEscrow.sol              ← the protocol's heart (5-state)
│   │   ├── FxOracle.sol                 ← per-pair FX with TTL
│   │   ├── SetPaymentBatch.sol
│   │   └── SetPaymaster.sol
│   ├── stablecoin/
│   │   ├── SSDC.sol + NAVOracle.sol     ← rebasing T-bill-backed stable
│   │   └── interfaces/
│   ├── test/                            ← OrderEscrow, FxOracle, SetRegistry, NAVOracle
│   └── script/DeployLocal.s.sol         ← anvil deploy + 4 FX seeds
│
├── bridges/               Node (ethers) — fiat ↔ SSDC HTTP servers
│   ├── on-ramp.mjs                      ← Stripe webhook → SSDC mint
│   └── off-ramp.mjs                     ← signed payout → SSDC pull
│
├── demos/                 Node + shell — exercise the stack end-to-end
│   ├── escrow-lifecycle.mjs             ← simplest, ethers-only
│   ├── realmoney-loop.mjs               ← full multi-currency cycle
│   ├── verify-receipt.mjs               ← 3-layer audit (schema, on-chain, STARK)
│   └── audit-with-cast.sh               ← pure shell, no Node
│
├── schemas/               JSON Schemas (3 receipt formats)
└── stack/stateset         single-entry CLI orchestrator
```

### Upstream (referenced, not bundled)

| Repo | Role |
|---|---|
| [`stateset/stateset-sequencer`](https://github.com/stateset/stateset-sequencer) | Rust (Axum + Postgres) — VES + x402 API |
| [`stateset/stateset-starks`](https://github.com/stateset/stateset-starks) | Rust (Winterfell) — STARK prover + `ves-stark` verifier CLI |
| [`stateset/icommerce-app`](https://github.com/stateset/icommerce-app) | Full platform monorepo: above + MCP tooling, admin UI, sync engine |

### Legacy mention (older monorepo paths in upstream icommerce-app)

```
ves-demo/              Node demos + bridges
├── agent-receipt.mjs                  hero
├── claude-agent-receipt.mjs           buyer + arbiter scenarios
│   ├── claude-agent-cfo.mjs               CFO scenario
│   ├── marketplace-fee/yield/...-demo     each commerce primitive
│   ├── cross-border-demo.mjs              multi-currency
│   ├── compliance-bundle-demo.mjs         3 STARK policies / tx
│   ├── supply-chain-demo.mjs              multi-tier B2B
│   ├── refund-timeout-demo.mjs            buyer protection
│   ├── subscription-yield-demo.mjs        recurring billing
│   ├── merchant-statement-demo.mjs        operator aggregation
│   ├── verify-receipt.mjs                 audit primitive (Node)
│   ├── audit-with-cast.sh                 audit primitive (pure shell)
│   ├── validate-receipt.mjs               JSON Schema check
│   ├── export-statement-csv.mjs           accounting export
│   ├── bridge-stripe-to-ssdc.mjs          fiat on-ramp
│   ├── bridge-ssdc-payout.mjs             fiat off-ramp
│   ├── bridge-mock-stripe-event.mjs       mock event sender
│   ├── bridge-mock-payout-request.mjs     mock seller-side withdraw
│   └── realmoney-loop-demo.mjs            full loop end-to-end
│
├── schemas/               JSON Schema 2020-12
│   ├── agent-receipt.v1.schema.json
│   ├── cross-border-receipt.v1.schema.json
│   └── compliance-bundle.v1.schema.json
│
├── dashboard/             zero-dep static HTML operator UI
│   └── index.html  (12.7 KB)
│
├── bin/
│   └── stateset           unified CLI dispatcher
│
├── docs/
│   ├── COMPETITIVE.md     vs Stripe / Shopify / PayPal etc.
│   └── ARCHITECTURE.md    this file
│
├── THESIS.md              the narrative
├── README.md              the front door
└── setup.sh               one-command bring-up + thesis tour
```

## Where each guarantee comes from

| Guarantee the protocol claims | Specific code that delivers it |
|---|---|
| "Funds physically move on chain" | `SSDC.transferFrom()` in `release()` / `refund()` / `resolveDispute()` |
| "Platform doesn't hold the funds" | `OrderEscrow` is a smart contract, not a custodial wallet; operator only has admin permissions over Disputed orders |
| "No chargebacks" | `release()` once funds are sent; on-chain, irreversible. (Stripe-side chargebacks are off-protocol risk to be handled at the bridge layer.) |
| "Buyer can always recover funds" | `refund()` after `deliveryDeadline`, callable only by buyer, no operator approval |
| "Marketplace fees are programmable" | `lockWithFee(feeRecipient, feeBps)` — atomic split inside `_payoutToSeller` |
| "Yield is yours" | SSDC rebasing (NAV-driven) + `sweepYield()` for the per-order surplus |
| "Multi-currency without trust" | `FxOracle.convert()` — quote stored on chain, freshness enforced, applied rate bound into `deliveryReceiptHash` |
| "Compliance is portable" | Three independent STARK policies per `compliance-bundle`; each verifiable per-policy |
| "Anyone can audit" | `verify-receipt.mjs` (Node) and `audit-with-cast.sh` (pure shell) re-check every claim against chain + run STARK byte-level verification |
| "Receipts are interop" | `schemas/*.json` (JSON Schema 2020-12) + `validate-receipt.mjs` (ajv) |
| "AI agents can drive everything" | 11 MCP tools in `cli/src/tools/agent-receipt.js` |

## What this architecture does NOT do

Bullet honesty:

1. **STARK proof bytes are not validated on chain.** SetRegistry stores the proof hash; the verification is off-chain (Winterfell verifier). A future Solidity verifier (or precompile) would close this. Until then, the chain has cryptographic *commitment* to the proof but doesn't itself enforce the proof's claims — verifiers (regulators, auditors) must run `ves-stark verify` themselves.
2. **The operator role is privileged.** Disputed-state resolution, sweep-yield, NAV attestation, and FX quote posting are operator-only. In production these need multi-sig with rotation; v1 ships with single-key admin for demo simplicity.
3. **No on-chain identity / KYC.** The protocol assumes the operator (or merchant onboarding flow) handles KYC off-chain. The `agent.authorization.v1` STARK policy is the closest primitive: prove an agent has authorization without revealing identity. Full identity is out of scope.
4. **No private mempool / MEV protection.** Front-running risks exist on the L2; production should pair with a sequencer that supports private mempools or threshold encryption.
5. **No real Stripe Treasury wiring.** The off-ramp returns a Stripe-Treasury-shaped intent; the actual `OutboundPayment.create` call is mocked. Same field shapes.

These are honest gaps. None of them block the runnable demos; all of them matter for production deployment beyond the local Anvil stack.
