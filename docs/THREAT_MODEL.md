# StateSet Threat Model

The honest counterpart to [ARCHITECTURE.md](./ARCHITECTURE.md). Every claim of "the protocol guarantees X" needs a corresponding "and here's how it could fail." This doc enumerates the threats, names the mitigations in code, and is explicit about what's residual risk we haven't closed yet.

Structure follows STRIDE — spoofing, tampering, repudiation, information disclosure, denial of service, elevation of privilege — applied to the commerce stack.

## Trust assumptions (what we're betting on)

The protocol's safety reduces to these assumptions. If any one of them fails, the corresponding guarantees fail with it.

| # | Assumption | Where it lives | If broken |
|---|------------|----------------|-----------|
| A1 | Set Chain L2 producers don't censor or reorder maliciously beyond ~12 blocks | OP Stack consensus | Sequencer can transiently omit transactions; rollup soft-finality protects against indefinite censorship |
| A2 | secp256k1 signatures are unforgeable without the private key | EVM precompile + ethers `verifyMessage` | Buyer/seller wallets can be impersonated → full custody loss |
| A3 | Ed25519 signatures (VES events) are unforgeable | sequencer's signature check on event ingest | Forged event lineage; STARK proof would still need a valid witness |
| A4 | HMAC-SHA256 with a kept-secret webhook key is unforgeable | `bridge-stripe-to-ssdc.mjs` | Forged payments minted as SSDC out of thin air |
| A5 | Winterfell STARK soundness holds (~82-bit) | `stateset-stark` (Rust) | False compliance attestations could pass verification |
| A6 | NAVOracle attestations are honest about T-Bill valuations | NAVOracle.attestNAV(), `onlyAttestor` | Fake yield could be minted into circulation |
| A7 | Operator (sequencer/treasury) doesn't collude against users | OrderEscrow's split of buyer / seller / operator powers | Disputed orders could be steered to favor colluding party |
| A8 | EVM doesn't have undisclosed precompile bugs | the chain itself | Out of our scope; same risk as every other smart contract |

## STRIDE table

### Spoofing — pretending to be someone else

| Threat | Mitigation | Code | Residual |
|--------|------------|------|----------|
| Forged Stripe webhook to mint SSDC | HMAC-SHA256 over `${t}.${rawBody}` with shared secret; 5-min timestamp tolerance; constant-time compare | [`verifyStripeSignature`](../ves-demo/bridge-stripe-to-ssdc.mjs) | Bridge operator's webhook secret in env → must be in a sealed secret store in production |
| Forged payout request claiming to be seller | secp256k1 signature on a canonical message bound to seller address, nonce, chainId, timestamp | [`payoutMessage` + `verifyMessage`](../ves-demo/bridge-ssdc-payout.mjs) | None at protocol; relies on seller wallet hygiene |
| Forged VES event in the sequencer | Each event Ed25519-signed by its agent; sequencer rejects on signature mismatch | sequencer ingest pipeline | None at protocol |
| Forged STARK proof | Winterfell verifier rejects under A5 | `ves-stark verify` (off-chain), `audit-with-cast.sh` | A5 (~82-bit security; multi-prover composition for higher) |
| Sybil — one agent claiming to be many | Unaddressed at protocol; agents are EOAs | — | KYC/identity is off-chain ops concern |

### Tampering — changing data in flight or at rest

| Threat | Mitigation | Code | Residual |
|--------|------------|------|----------|
| Modify a receipt JSON between issuer and verifier | Receipt's claims re-checked by `verify-receipt.mjs` against the chain — receipt is metadata, the chain is truth | [`verify-receipt.mjs`](../demos/verify-receipt.mjs) | None for chain-anchored claims; the receipt itself is just a convenience surface |
| Modify a STARK proof file | Proof bytes hash to the same `proofHash` committed on chain; verifier rejects mismatch | `commitBatchWithStarkProof` + `verifyStarkProofHash` | None |
| Manipulate FX rate between quote and lock | Quote's `updatedAt` + TTL enforced on every `convert()` read; rate stamped into `deliveryReceiptHash` at lock time | [`FxOracle.getQuote`](../contracts/commerce/FxOracle.sol) | Operator can post arbitrarily wrong quote (A6-class); v2 should accept multi-source attestation |
| Tamper with sequencer's commitment after it's anchored | `SetRegistry.commitments[batchId]` is immutable post-write; state-chain continuity enforced under strict mode | `SetRegistry._validateAndStoreBatch` | None |
| Front-run an `escrow.lock` to steal the order | Order is keyed on caller-supplied `orderId`; only the buyer can lock with their funds | `OrderEscrow.lock` | None — locking is buyer-specific |
| Inject a different intent into a Merkle batch | `verifyPaymentInclusion` checks Merkle path; sequencer can't include intents the original signer didn't sign | `SetPaymentBatch.verifyPaymentInclusion` | Sequencer can refuse to include valid intents (censorship; A1-class) |

### Repudiation — denying you did something

| Threat | Mitigation | Code | Residual |
|--------|------------|------|----------|
| Buyer claims they didn't authorize a purchase | secp256k1 signature on x402 PaymentIntent + on-chain `lock()` from buyer's wallet | `agent-receipt.mjs` Phase 3 | None — every action is buyer-signed |
| Seller claims they delivered when they didn't | `markDelivered` is buyer-only; `release()` requires status == Delivered | `OrderEscrow.markDelivered` (modifier) | None — buyer is the gatekeeper of delivery confirmation |
| Operator claims they followed dispute resolution policy | `DisputeResolved` event on chain with operator address + `inFavorOfSeller` bool | `OrderEscrow.resolveDispute` | Operator's *off-chain* reasoning is opaque — v2 wants verifiable reasoning attestation |
| Bridge operator claims they processed a Stripe payout | `OutboundPayment.id` returned synchronously; `pull_tx` on chain provides the SSDC-side proof | bridges return both | Stripe-side `posted` webhook handling is operational TODO |

### Information disclosure — leaking data

| Threat | Mitigation | Code | Residual |
|--------|------------|------|----------|
| On-chain transaction reveals exact order amount | Public on-chain by design | — | STARK policy proofs *don't* leak the amount; auditors see only the bound (`amount ≤ cap`, etc.) |
| FX rate manipulation reveals trader intent (MEV) | Lock + release happen in separate txs but quote is read at lock time | — | Standard L2 MEV concern; production should pair with private mempool |
| PII in receipt JSONs | Schemas enforce no name/email/SSN fields; receipts only hold wallets, hashes, amounts | [`schemas/*.json`](../schemas/) | Operators must not append PII into custom metadata |
| Compliance bundle reveals correlated identity | Each STARK proof attests one bound; the *bundle* could over-correlate if shared as one packet | — | Per-policy distribution model: hand each verifier only the proof they need |
| Stripe webhook leaks customer data via verbose logs | Webhook bodies are NOT logged; only `event.type` + minted amount + tx hash | bridge log format | Operator must keep logs out of public observability stacks |

### Denial of service

| Threat | Mitigation | Code | Residual |
|--------|------------|------|----------|
| Spam the sequencer with bogus events | Per-tenant rate-limits on event ingest; signed events only | sequencer admin config | Out-of-protocol DDoS is an ops concern |
| Lock 1 wei to clog escrow with millions of zombie orders | `lock()` requires `amount > 0`; gas costs scale per-order | `OrderEscrow.lock` ZeroAmount check | An attacker could still spam small-but-nonzero locks; future: minimum-amount config |
| Stripe webhook flood | Standard L7 DoS → CDN/rate-limit upstream | — | Operational |
| FX oracle goes silent (operator stops posting) | `convert()` reverts cleanly; cross-border txs fail-closed (no settlement at unknown rate) | `StaleQuote` revert | Multi-source FX (v2) eliminates single-point dependency |
| NAVOracle stops attesting | SSDC keeps the last-known NAV; no rebase, but no incorrect rebase either | NAVOracle staleness handling in SSDC | Yield stops accruing; principal protected |

### Elevation of privilege

| Threat | Mitigation | Code | Residual |
|--------|------------|------|----------|
| Operator (sequencer key) drains all escrowed funds | `release()` requires status==Delivered; can't be set by operator (only buyer or operator-via-resolveDispute on Disputed orders) | `OrderEscrow` modifiers | Operator can resolve a Disputed order in favor of seller; not an unconditional drain. v2 wants multi-sig + dispute-arbitrer rotation |
| Operator mints unlimited SSDC | `SSDC.mintShares` is `onlyTreasury`; treasury wallet is configured at init | `SSDC.setTreasuryVault` | Treasury wallet must be multi-sig in production; single-key now |
| Authorized sequencer falsifies state-root commit | `setStrictMode(true)` enforces state-chain continuity (each batch's `prevStateRoot` must match the previous batch's `newStateRoot`) | `SetRegistry._validateAndStoreBatch` strict-mode branch | If `setStrictMode(false)`, sequencer can fork the state chain — operationally never disable |
| Authorized sequencer commits a fake STARK proof | Hash committed on chain; `audit-with-cast.sh` catches mismatch when verifying proof bytes | `commitStarkProof` + `getStarkProofDetails` | Until on-chain Solidity verifier exists, the chain commits to a hash; verifiers must run the off-chain verifier themselves |
| Bridge operator key compromise → mass mint | Treasury wallet is the same key; rate-limiting + per-day cap belongs in the bridge layer in production | — | Currently no rate-limit. Production must add: per-day mint ceiling, multi-sig escape, monitoring on `Transfer(to=…0)` reversal pattern |
| OrderEscrow upgrade to a malicious implementation | OrderEscrow is **not** UUPS upgradeable — it's a plain contract | `OrderEscrow.sol` no `_authorizeUpgrade` | None for OrderEscrow. SetRegistry/SetPaymentBatch/SetPaymaster/SSDC/NAVOracle are UUPS — production should multi-sig the proxy admin |

## Threats specific to the commerce shape

These don't cleanly fit STRIDE but matter for an honest evaluation.

| Threat | Mitigation | Residual |
|--------|------------|----------|
| Stripe-side chargeback after webhook fired | None at protocol — bridge already minted SSDC | **Operational risk** the bridge operator absorbs. In production: hold mint behind a 7-day reversal window, use Stripe's `dispute.created` webhook to claw back |
| Buyer signs a `lock` with insufficient balance | Reverts cleanly via SSDC's `transferFrom`; no partial state | None |
| Seller's wallet is sanctioned mid-order | OFAC screening is off-protocol | The `agent.authorization.v1` STARK policy is the place to enforce; v2 |
| MEV: a searcher front-runs `release()` to extract from the seller | Release is no-arb; no value to extract by reordering | None |
| MEV: the FX oracle's update is sandwich-attacked | The quote update + the lock are operator-coordinated; if a buyer's `lock()` lands between two oracle updates, the rate they get is the chain-finalized one | Production: explicit rate-binding via signed quote per-order |
| Replay an old payout request signature | `usedNonces[seller][nonce]` blocks duplicates; 5-min timestamp tolerance | None |
| Replay an old Stripe webhook | Stripe sends idempotency keys; bridge currently doesn't dedupe by them | **Production gap** — track event.id in a TTL cache |
| Buyer and seller collude to launder funds via fake disputes | Dispute resolution requires operator approval | Operator's discretion is the bottleneck; v2 multi-sig |
| Subscription fork: subscriber stops paying after taking a "free" cycle | Each cycle is independent — escrow only releases for delivered cycles | None |
| Multi-tier supply chain leg fails mid-flight (manufacturer reneges) | Each leg is independent OrderEscrow; tier-2 refund timeout protects wholesaler | None |

## What we have NOT mitigated

Bullet honesty:

1. **No on-chain STARK proof validation.** The chain commits to the proof's hash; the actual cryptographic verification happens off-chain with Winterfell. A regulator with a stake claim *must* run the verifier themselves (via `verify-receipt.mjs` or `audit-with-cast.sh`). A v2 Solidity verifier (or precompile) would close this.
2. **Operator role is single-key in current contracts.** `OrderEscrow.operator`, `SSDC.treasuryVault`, `NAVOracle.authorizedAttestors`, `SetRegistry.authorizedSequencers`, `FxOracle.operator` — every one is single-key in the demo deploy. Production *must* multi-sig these.
3. **Bridge layer has no rate limits.** `mintShares` is gated only by treasury-key custody. Per-day caps + monitoring are required before any mainnet exposure.
4. **No dispute escalation tier.** A dispute resolves in favor of one party once the operator picks. Production wants buyer-can-appeal logic, possibly to a second-tier arbiter.
5. **Stripe chargeback / refund handling is operational.** The mint is irreversible from the bridge's perspective; if the buyer chargebacks, the operator is on the hook for the SSDC.
6. **No private mempool integration.** Set Chain L2 transactions are visible to MEV searchers like any other rollup. Production should pair with a sequencer that supports private inclusion or threshold encryption.
7. **No on-chain identity / sanctions screening.** Out of scope for the protocol layer; pushed to merchant-onboarding flows.

## How to validate this threat model

Every line above maps to either:
- **A specific contract function or modifier** — verify by reading the [`contracts/`](../contracts/) source
- **A specific bridge primitive** — verify by reading [`bridges/on-ramp.mjs`](../bridges/on-ramp.mjs) / [`off-ramp.mjs`](../bridges/off-ramp.mjs)
- **A specific test in the Foundry suite** — `cd contracts && forge test --match-contract OrderEscrow` runs 13/13 green; `--match-contract FxOracle` runs 7/7; `--match-contract NAVOracle` runs 27/27
- **A demo that exercises the path** — `./stack/stateset demo lifecycle` and `./stack/stateset demo realmoney --currency JPY --payout-currency GBP`
- **A documented gap** — listed in the "NOT mitigated" section, not glossed

If you're running an enterprise security review on this stack, the artifacts to read are this doc, [ARCHITECTURE.md](./ARCHITECTURE.md), and the Foundry test output. Together they cover threat → mitigation → test → demo for every claim the protocol makes.
