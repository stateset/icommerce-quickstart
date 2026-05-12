# Example run

What you'll actually see when running through the 5-minute start. Use this to verify your local run matches expectation.

> Generated from the scripts at `0x6981972`. Output may vary slightly between Foundry / anvil versions; what matters is the structure (✓ checks, status transitions, balance deltas).

---

## 0. First-time setup

```text
$ bash stack/setup.sh

icommerce-quickstart setup — installing Solidity + Node deps

  → forge install foundry-rs/forge-std
  → forge install OpenZeppelin/openzeppelin-contracts@v5.0.0
  → forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.0.0
  ✓ contracts/lib ready (3 libs)
  → npm install in bridges/
  → npm install in demos/
  ✓ bridges/ + demos/ npm deps installed

✓ setup complete
  Next: ./stack/stateset up    (start anvil + deploy + bridges)
        ./stack/stateset test  (forge test + bridge tests + demo syntax)
```

Idempotent — re-running skips deps already installed.

---

## 1. Bring everything up

```text
$ ./stack/stateset up

  ✓ anvil started (chain 84532001)
  → deploying contracts to http://localhost:8545…
  ✓ contracts deployed (see contracts/broadcast/)
  ! seed-fx not yet implemented in quickstart; FX quotes are seeded by DeployLocal
  → starting on-ramp…
  ✓ on-ramp started :4242
  → starting off-ramp…
  ✓ off-ramp started :4243

  ✓ stack is up. try: ./stack/stateset demo lifecycle
```

---

## 2. The hero demo: escrow-lifecycle

```text
$ ./stack/stateset demo lifecycle

━━━ OrderEscrow lifecycle demo — $1500 order ━━━
  RPC:    http://localhost:8545
  escrow: 0xa513e6e4b8f2a923d98304ec87f64353c4d5c853
  SSDC:   0xa51c1fc2f0d1a1b8494ed1fe312d7c3a78ed91c0

Before
  buyer  0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC  100000.00 SSDC
  seller 0x90F79bf6EB2c4f870365E785982E1f101E93b906  10000.00 SSDC

1. buyer approves escrow as SSDC spender…
   ✓ approved $1500

2. buyer locks $1500 into escrow (orderId 0x64f68b844691102b…)…
   ✓ locked  tx 0x3f09a98415eaed1bbbef51e6f6b866f467707f08f6dcb4be89b9a7524e796224  block 24
   ✓ buyer −1500.00  escrow +1500.00  status=Locked

3. buyer markDelivered (confirms receipt, w/ delivery-receipt hash)…
   ✓ delivered  tx 0x...  block 25
   ✓ escrow still holds 1500.00  status=Delivered

4. seller release() (after confirmation window)…
   ✓ released  tx 0x...  block 26
   ✓ escrow drained  seller +1500.00  status=Released

After
  buyer  98500.00 SSDC  (Δ -1500.00)
  seller 11500.00 SSDC  (Δ +1500.00)

✓ escrow lifecycle complete — 8 invariants asserted: buyer paid, escrow held + drained, seller paid, statuses correct.
```

Each `✓` line is a real on-chain assertion. If any of these would fail, the demo throws (exit 1) — that's exactly what the e2e CI step relies on.

---

## 3. Health check

```text
$ ./stack/stateset doctor

  OK    forge Version: 1.5.1-dev
  OK    node v20.20.2
  OK    cast available
  OK    forge-std installed
  OK    openzeppelin-contracts installed
  OK    anvil http://localhost:8545
  OK    contracts deployed
  OK    on-ramp
  OK    off-ramp
  OK    FX quotes fresh (4/4 pairs)
  OK    schemas/ present (3 files)
  !     ves-stark not on PATH (set STARK_BIN if you have it; only needed for compliance bundles)
```

`--fix` auto-remediates: re-deploys contracts if missing, restarts bridges if stopped, re-seeds stale FX quotes.

Companion command — `./stack/stateset show` — prints the chain-state view:

```text
Chain state @ http://localhost:8545
  block             50931
  SSDC              0xa51c1fc2f0d1a1b8494ed1fe312d7c3a78ed91c0
    totalSupply     110000.00 SSDC
  NAVOracle         0xb0d4afd8879ed9f52b28595d31b441d079b2ca07
    NAV/share       $1.00
  FxOracle          0x96f3ce39ad2bfdcf92c0f6e2c2cabf83874660fc
    ✓ EUR/ssUSD → 1.0625 ssUSD/unit
    ✓ GBP/ssUSD → 1.27 ssUSD/unit
    ✓ JPY/ssUSD → 0.0064 ssUSD/unit
    ✓ MXN/ssUSD → 0.059 ssUSD/unit
```

---

## 4. The fast path: just check it works

```text
$ ./stack/stateset test

  → contracts (forge test)…
  Suite result: ok. 13 passed; 0 failed; 0 skipped (OrderEscrow)
  Suite result: ok.  7 passed; 0 failed; 0 skipped (FxOracle)
  Suite result: ok. 27 passed; 0 failed; 0 skipped (NAVOracle)
  Suite result: ok. 46 passed; 0 failed; 0 skipped (SetRegistry)
  Suite result: ok. 48 passed; 0 failed; 0 skipped (SetPaymaster)
  Suite result: ok. 75 passed; 0 failed; 0 skipped (SetPaymentBatch)
  Ran 6 test suites: 216 tests passed, 0 failed, 0 skipped (216 total)

  → bridges (node --test)…
  ℹ tests 35
  ℹ pass 35
  ℹ fail 0

  → demo syntax check…
  OK    demos syntax OK
```

---

## 5. Multi-currency (Tokyo buys, London withdraws)

```text
$ ./stack/stateset demo realmoney --currency JPY --payout-currency GBP

━━━ Phase 1: Stripe webhook → SSDC ━━━
  ✓ ¥235000 JPY checkout.session.completed signed (HMAC v1)
  ✓ on-chain FX quote JPY/ssUSD: 0.0064 (TTL 60min)
  ✓ minted 1504.00 SSDC to 0x3C44Cd... (rate 0.0064 from FxOracle)

━━━ Phase 2: SSDC → OrderEscrow → seller ━━━
  ✓ buyer locked 1504.00 SSDC into escrow
  ✓ delivered + released
  ✓ seller balance: +1504.00 SSDC

━━━ Phase 3: SSDC → Stripe Treasury → bank ━━━
  ✓ seller signed payout request (£1180 GBP, secp256k1, chainId-bound)
  ✓ pulled 1498.60 SSDC (rate 1.27 from FxOracle, GBP/ssUSD)
  ✓ Stripe Treasury intent: obp_xxx  ETA 2026-05-08

✓ Tokyo→London cycle complete. SSDC core: same. FX rates: on-chain auditable.
```

The on/off-ramp both read the same on-chain `FxOracle` for non-USD conversion, so a regulator or auditor can replay any rate at the recorded `updatedAt` timestamp.

---

## What you should see if anvil isn't up

```text
$ ./stack/stateset doctor

  OK    forge Version: 1.5.1-dev
  OK    node v20.20.2
  OK    cast available
  OK    forge-std installed
  OK    openzeppelin-contracts installed
  FAIL  anvil down
  !     contracts not deployed
  !     on-ramp down
  !     off-ramp down
```

Then `./stack/stateset up` (or `./stack/stateset doctor --fix`) brings it all back.

---

## CI behavior

Every push to `main` runs three jobs in parallel:

| Job | What it does | Time |
|---|---|---|
| `contracts (foundry)` | `forge install` (pinned OZ v5.0.0) → `forge fmt --check` → `forge build --sizes` → `forge test` | ~5 min |
| `bridges (node --test)` | 41 unit tests, no chain required | ~10 s |
| `demos (syntax + escrow-lifecycle e2e)` | syntax check → boot anvil → deploy → run `escrow-lifecycle.mjs` with 9 invariant assertions | ~5 min |

Green badge on the README means all 3 passed. The demos job is the strictest — it asserts that contract math actually balances, not just that no tx reverted.
