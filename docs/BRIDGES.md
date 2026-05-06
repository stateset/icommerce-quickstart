# Bridges — production deployment guide

How to take the StateSet on-ramp / off-ramp bridges from the local demo to a real Stripe + EVM deployment. Pairs with [ARCHITECTURE.md](./ARCHITECTURE.md) (system diagrams) and [THREAT_MODEL.md](./THREAT_MODEL.md) (what could break).

The demo code in `ves-demo/bridge-stripe-to-ssdc.mjs` and `ves-demo/bridge-ssdc-payout.mjs` is **production-shaped, not production-ready** — every signature scheme, message format, and ABI matches what real Stripe expects, but several hardening steps must be added before mainnet exposure. Each is listed below with the specific code change.

---

## On-ramp: Stripe webhook → SSDC mint

### What the demo does

```
POST /webhook
  ├─ verifyStripeSignature(rawBody, Stripe-Signature, secret)   ← HMAC-SHA256
  ├─ parse checkout.session.completed event
  ├─ if currency != USD → FxOracle.convert(pair, amount)         ← on-chain
  └─ SSDC.mintShares(buyerWallet, amount)                        ← treasury-only
```

### What you need to add for production

#### 1. Replace shared secret with per-environment Stripe webhook signing secret

Stripe's webhooks endpoint configuration page gives you a `whsec_…` secret per endpoint. **Use a separate secret for live vs. test mode, and per-environment.** Store in your secrets manager (Vault, AWS Secrets Manager, GCP Secret Manager, etc.) — never in `.env` files committed to git.

```bash
STRIPE_WEBHOOK_SECRET=whsec_live_REPLACE_ME_FROM_STRIPE_DASHBOARD
```

The HMAC verification in `bridge-stripe-to-ssdc.mjs` works unchanged.

#### 2. Idempotency — track event IDs

Stripe retries webhooks aggressively (up to 3 days). The demo bridge will mint SSDC twice if it processes the same event twice. **Production must dedupe by `event.id`.**

```js
// Add a Redis (or Postgres unique index) check before handleEvent():
const seen = await redis.set(`stripe:event:${event.id}`, '1', { NX: true, EX: 7 * 86400 });
if (!seen) return res.status(200).end();   // already processed
```

#### 3. Treasury wallet — multi-sig + rate limit

The treasury private key in the demo is anvil[0]. In production:

- **Use a multi-sig** (Safe, Fireblocks, ZenGo) for `SSDC.setTreasuryVault`
- **Use a hot wallet** with limited daily mint budget for the actual bridge calls
- **Rotate keys** quarterly; monitor for `Transfer(to, 0)` patterns that suggest compromise

A simple rate limit:

```js
const dayKey = new Date().toISOString().slice(0, 10);
const minted = Number(await redis.incrby(`stripe:minted:${dayKey}`, sharesToMint));
if (minted > MAX_DAILY_MINT) {
  throw new Error(`exceeded daily mint cap of ${MAX_DAILY_MINT}`);
}
```

#### 4. Chargeback handling

When the buyer disputes the original card charge, Stripe fires `charge.dispute.created` (and eventually `charge.dispute.closed`). The bridge has already minted SSDC; you cannot un-mint it from a buyer wallet that may have spent it.

Two production strategies:

- **Hold mint behind a 7-day reversal window:** mint into a custodial sub-account; only release to the buyer's wallet after no dispute has fired
- **Insurance pool:** maintain a reserve sized to expected chargeback rate (typically 0.1–0.6% of GMV), funded by platform fees

The demo doesn't implement either — chargeback risk is currently the bridge operator's full liability.

#### 5. Webhook reliability (delivery semantics)

Stripe expects HTTP 200 within 30 seconds. The demo bridge does the on-chain mint synchronously — fine for a few-second mint, but a degraded RPC will time out the webhook.

Production pattern:

```js
// Phase 1: ack the webhook fast
async function onWebhook(req, res) {
  verifyStripeSignature(...);
  await queue.publish('stripe.event', event);   // outbox table or Kafka
  return res.status(200).end();
}

// Phase 2: process from the queue, with retries + dedupe
async function processEventWorker(event) {
  await mintWithIdempotency(event);
}
```

#### 6. Monitoring

Per-event metrics:

- mint latency (p50/p99)
- mint failures by reason (stale FX, allowance, RPC error)
- daily mint volume per currency
- webhook signature failures (security signal)
- balance of treasury hot wallet (drain alarm)

Alarms:

- treasury balance below 30-day expected max
- mint failure rate above 1%
- single buyer wallet receiving >$10,000 in 1 hour (manual review)

---

## Off-ramp: signed payout request → Stripe Treasury intent

### What the demo does

```
POST /payout
  ├─ verify seller's signature on canonical message
  ├─ check usedNonces[seller][nonce] for replay
  ├─ check 5-minute timestamp tolerance
  ├─ SSDC.transferFrom(seller, treasury, amount)                ← bridge pulls
  └─ return mock Stripe Treasury OutboundPayment intent
```

### What you need to add for production

#### 1. Wire the real Stripe Treasury OutboundPayment.create

The mock function `mockOutboundPayment(...)` returns a Stripe-Treasury-shaped object. Replace with the real call:

```js
import Stripe from 'stripe';
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

const op = await stripe.treasury.outboundPayments.create({
  amount: Math.round(amountUsd * 100),
  currency: 'usd',
  financial_account: process.env.STRIPE_FINANCIAL_ACCOUNT_ID,  // your Treasury account
  destination_payment_method: paymentMethodId,                  // pre-saved bank account
  description: `StateSet SSDC payout for ${seller}`,
  metadata: {
    stateset_seller_wallet: seller,
    stateset_pull_tx: rcpt.hash,
  },
});
```

Field shapes are identical to the mock — same `id`, `amount`, `currency`, `status`, `expected_arrival_date`, etc. The `processing` → `posted` transition will arrive via `treasury.outbound_payment.posted` webhook.

#### 2. Persist nonce usage durably

The demo uses an in-memory `Map`. Production must use a database — a single bridge restart would otherwise let an attacker re-submit a replay.

```sql
CREATE TABLE payout_nonces (
  seller_wallet  CHAR(42)   NOT NULL,
  nonce          CHAR(34)   NOT NULL,
  consumed_at    TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (seller_wallet, nonce)
);
```

Insert with `ON CONFLICT DO NOTHING`; if no row was inserted, the nonce was already used.

#### 3. KYC / sanctions screening

Stripe Treasury requires the destination bank account to be tied to a verified Stripe Connect account. Before allowing a wallet to claim a payout, you must have:

- linked the wallet to a Connect account ID via merchant onboarding
- confirmed the destination bank is in the Connect account's verified payment methods
- run OFAC + sanctions screening (Stripe does this for you on the Connect side, but you should also screen the wallet address against on-chain sanctions oracles like Chainalysis Sanctions Screening Oracle)

#### 4. Per-currency support

The demo's off-ramp is USD-only. Stripe Treasury supports multi-currency via region-specific financial accounts:

- `usd` → US Treasury account
- `gbp` → UK FinAcc (Stripe Issuing UK)
- `eur` → EUR FinAcc (Stripe Issuing EU)

Same `OutboundPayment.create` call, just different `currency` + matching `financial_account`. Add an env-var map:

```js
const FA_BY_CURRENCY = {
  usd: process.env.STRIPE_FA_USD,
  gbp: process.env.STRIPE_FA_GBP,
  eur: process.env.STRIPE_FA_EUR,
};
```

#### 5. Settlement worker — close the loop

After the bridge pulls SSDC into its treasury, the settlement worker should burn it once the Stripe Treasury payout posts:

```js
// Subscribed to treasury.outbound_payment.posted webhook
async function onPayoutPosted(event) {
  const pullTx = event.data.object.metadata.stateset_pull_tx;
  const amountSsUsd = await lookupAmountForPullTx(pullTx);
  await ssdc.burnShares(bridgeTreasury, parseUnits(amountSsUsd.toString(), 18));
  console.log(`burned ${amountSsUsd} SSDC matching posted payout ${event.data.object.id}`);
}
```

This keeps the SSDC supply in line with the real fiat float held in Stripe Treasury.

#### 6. Reverse path: Stripe ACH return / failure

ACH returns can come up to 60 days after `posted` (R-codes for invalid account, frozen, etc.). When this happens:

- `treasury.outbound_payment.failed` webhook fires
- bridge must `mintShares` back to the seller's wallet (or hold in a "returned" sub-account)
- seller is notified (off-platform UX)

---

## Deployment checklist

### Pre-deployment

- [ ] Foundry contracts deployed to your target network (Base, OP Mainnet, Set Chain)
- [ ] `OrderEscrow` operator multi-sig created (e.g. Safe with 3-of-5 threshold)
- [ ] `SSDC.treasuryVault` set to a multi-sig
- [ ] `NAVOracle` attestor multi-sig configured
- [ ] `FxOracle` operator multi-sig configured
- [ ] Initial FX quotes posted with appropriate TTLs
- [ ] OrderEscrow tested on chain with a manual round-trip (lock → release)

### On-ramp bridge

- [ ] `STRIPE_WEBHOOK_SECRET` configured (live secret, in secrets manager)
- [ ] Treasury hot wallet funded; daily mint cap set
- [ ] Idempotency store wired (Redis or Postgres unique index)
- [ ] Async webhook handler (queue + worker pattern)
- [ ] Monitoring + alarms configured
- [ ] Chargeback strategy decided (hold-window vs. insurance pool)
- [ ] Stripe webhook endpoint registered in dashboard, pointing at your bridge URL
- [ ] Smoke test: `stripe trigger checkout.session.completed --add metadata[buyer_wallet]=0x…`

### Off-ramp bridge

- [ ] `STRIPE_SECRET_KEY` configured
- [ ] Stripe Treasury financial accounts created per currency
- [ ] Connect onboarding flow built for sellers
- [ ] Bank account verification flow built (Stripe-hosted)
- [ ] Sanctions screening (on-chain + Stripe Connect)
- [ ] Persistent nonce database (Postgres recommended)
- [ ] Settlement worker subscribed to `treasury.outbound_payment.posted`
- [ ] Reversal handler subscribed to `treasury.outbound_payment.failed`
- [ ] Smoke test: signed payout request → real ACH initiated → posted webhook received

### Operational

- [ ] Runbook for bridge operator key compromise
- [ ] Daily reconciliation job (SSDC supply ↔ Stripe Treasury balance)
- [ ] Weekly auditor handoff (receipts → CSV export → finance)
- [ ] Quarterly penetration test on bridge endpoints
- [ ] Insurance pool funded (or confirmed chargeback acceptance with risk team)

---

## Reference call graph

```
                  ┌──────────────────────┐
                  │  Stripe (live)       │
                  └──────┬───────────┬───┘
                         │           ▲
                checkout │           │ treasury.outbound_payment
                .session │           │ .posted / .failed
                .completed           │
                         ▼           │
              ┌─────────────────────────────┐
              │  on-ramp bridge              │      ┌──────────────┐
              │  (this repo, hardened)        │◄─────┤  off-ramp    │
              └────┬────────────────────┬────┘     │  bridge       │
                   │                    │           └──┬───────────┘
       SSDC.mint   │                    │ FxOracle      │
                   ▼                    ▼               │ SSDC.transferFrom
              ┌─────────────────────────────────────┐  │
              │  Set Chain L2                       │◄─┘
              │  (or Base, Optimism, your L2)       │
              │                                     │
              │  • SSDC + NAVOracle                 │
              │  • OrderEscrow                      │
              │  • FxOracle                         │
              │  • SetRegistry                      │
              └─────────────────────────────────────┘
                              ▲
                              │ buyers / sellers
                              │ (autonomous agents
                              │  or human-driven UIs)
                              │
                              │
                  ┌────────────────────────┐
                  │  Merchant/agent host    │
                  │  consuming MCP tools    │
                  │  (Claude / OpenAI /     │
                  │   Cursor / custom)      │
                  └────────────────────────┘
```

---

## What this guide does NOT cover

Bullet honesty:

1. **Cross-chain bridging.** This guide assumes the on-chain stack runs on a single L2. Bridging SSDC across chains (e.g. for a buyer on Base buying from a seller on Set Chain) is its own protocol layer — see `LayerZero`, `CCIP`, or `Wormhole` for cross-chain routing.
2. **Tax reporting.** Stripe Treasury issues 1099-Ks for sellers; you must reconcile per-seller GMV from the merchant statement. Reference: the `seller_wallet` filter on `agent_receipt_merchant_statement` MCP tool.
3. **Customer support workflows.** When a buyer's order is stuck `Disputed`, who fixes it? Stripe's support is for the card transaction; the on-chain dispute resolution is the operator's responsibility. Build a CRM workflow that ties a Stripe `payment_intent.id` to an on-chain `orderIdHash`.
4. **GDPR / data-retention compliance.** Receipts contain wallet addresses + tx hashes (not PII). Your CRM and Stripe Connect onboarding will hold real PII; that's where data-retention policies belong, not in the receipts.

These are honest scope boundaries — the bridges + on-chain stack solve a specific commerce-rails problem, not the entire payment-platform compliance burden.
