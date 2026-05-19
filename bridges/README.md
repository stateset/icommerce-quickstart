# bridges — fiat ↔ SSDC

Two HTTP servers that bridge real banking events to the SSDC stablecoin.

| Bridge | Port | Direction | Auth |
|---|---|---|---|
| **on-ramp** (`on-ramp.mjs`) | 4242 | bank → SSDC | HMAC-SHA256 verification of Stripe `checkout.session.completed` webhooks |
| **off-ramp** (`off-ramp.mjs`) | 4243 | SSDC → bank | secp256k1-signed payout requests (canonical message binds seller, amount, currency, bank, nonce, issuedAt, chainId) |

## Run them

```bash
npm install

# Terminal 1
RPC_URL=http://localhost:8545 node on-ramp.mjs

# Terminal 2
RPC_URL=http://localhost:8545 node off-ramp.mjs
```

Or use the orchestrator: `../stack/stateset bridges` starts both in the background.

## Multi-currency

Both bridges accept **USD, EUR, GBP, JPY, MXN**. Non-USD reads `<CUR>/ssUSD` from the on-chain `FxOracle` so the rate is auditable at the recorded `updatedAt`.

The off-ramp message format is byte-deterministic: USD renders as `$200.00 USD` (byte-identical to v1, so legacy signatures still verify); JPY renders as integers (`¥30000 JPY`); etc. **Cross-currency replay is rejected by binding `outputCurrency` into the signed message** — signing a payout for GBP cannot be replayed as a USD payout even if the numeric amount matches.

## Tests

68 unit tests run **standalone with no chain**:

```bash
npm test
```

The bridges lazy-load their contract addresses from the broadcast log only on `bridge.start()` / `loadAddresses()`, so `node --test` can import the pure verification functions (`verifyStripeSignature`, `verifyPayoutRequest`, `payoutMessage`, plus the v0.8.0 `createDailyCap` / `createRateLimiter`) without a deployed chain.

## Env

| Var | Default | Used by |
|---|---|---|
| `RPC_URL` | `http://localhost:8545` | both |
| `BROADCAST_LOG` | `../contracts/broadcast/DeployLocal.s.sol/84532001/run-latest.json` | both |
| `STRIPE_WEBHOOK_SECRET` | `whsec_test_local_only` | on-ramp |
| `STRIPE_IDEMPOTENCY_DIR` | `../stack/.run/stripe-events` | on-ramp |
| `PAYOUT_NONCE_DIR` | `../stack/.run/payout-nonces` | off-ramp |
| `MAX_WEBHOOK_BYTES` | `1048576` | on-ramp request-size cap |
| `MAX_PAYOUT_BYTES` | `1048576` | off-ramp request-size cap |
| `MAX_DAILY_MINT_USD` | `100000` | on-ramp sliding 24h USD-equivalent volume cap (new in v0.8.0) |
| `MAX_DAILY_PAYOUT_USD` | `100000` | off-ramp sliding 24h USD-equivalent volume cap (new in v0.8.0) |
| `WEBHOOK_RATE_LIMIT_PER_MIN` | `120` | on-ramp per-source request rate limit (new in v0.8.0) |
| `PAYOUT_RATE_LIMIT_PER_MIN` | `60` | off-ramp per-source request rate limit (new in v0.8.0) |
| `BRIDGE_TRUST_PROXY` | unset | when `1`, take client IP from `X-Forwarded-For` (use only behind a known reverse proxy) |
| `TREASURY_KEY` | anvil[0] | on-ramp (mints SSDC) |
| `BRIDGE_TREASURY_KEY` | anvil[6] | off-ramp (receives pulled SSDC) |

## Limits

Each bridge exposes its current limits state on `GET /health`:

```bash
curl -s http://localhost:4242/health | jq .limits
# { "maxDailyMintUsd": 100000, "usedLast24h": 0, "rateLimitPerMin": 120 }
```

Daily caps survive process restarts — both bridges replay their durable idempotency directories on startup so a crash-restart cannot reset the 24h window. Exhausted caps and rate limits return HTTP `429` with `Retry-After` set, suitable for Stripe's automatic retry-with-backoff.

## Threat model

See `../docs/THREAT_MODEL.md` for the STRIDE breakdown. The short version: spoofing/tampering blocked by HMAC + secp256k1; cross-chain replay blocked by chainId in the signed message; cross-currency replay blocked by outputCurrency in the signed message; nonce replay blocked by per-seller nonce store; freshness windows on both sides; sliding 24h USD-equivalent volume cap + per-source rate limit close the "bridge has no quantitative limits" residual from v0.7.x.
