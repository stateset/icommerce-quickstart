// SPDX-License-Identifier: MIT
//
// Bridge layer rate limits + per-day volume caps.
//
// THREAT_MODEL.md §"Bridge operator key compromise → mass mint" and the v0.7.x
// unmitigated-list both flagged that the bridges had no quantitative limits:
// mintShares was gated only by treasury-key custody, so a leaked webhook secret
// + replay or a flood of valid-shaped events could mint without bound. This
// module is the two hardening surfaces the threat model required:
//
//   1. createDailyCap  — sliding 24h USD-equivalent volume cap, fail-closed.
//                        Bridge `check()`s before async chain work; `record()`s
//                        only on success. State rebuilds on startup from the
//                        durable idempotency directory so restarts don't reset
//                        the window.
//
//   2. createRateLimiter — per-source 60-second token bucket. Gates work *before*
//                          HMAC/signature verification so a flood cannot amplify
//                          crypto work. Keyed on caller-supplied id (typically
//                          remote IP).
//
// Both are explicit env-driven and fail-closed: an unparseable cap value
// aborts startup rather than falling through to "no limit".

import fs from 'node:fs';
import path from 'node:path';

const ONE_DAY_SEC = 24 * 60 * 60;
const ONE_MINUTE_SEC = 60;

/**
 * Sliding 24-hour cap on USD-equivalent volume.
 *
 * @param {object} opts
 * @param {number|"unlimited"} opts.maxUsd  Hard cap; pass "unlimited" only for tests.
 * @param {() => number} [opts.now]         Seconds-since-epoch source (test seam).
 * @param {Array<{ts:number, amountUsd:number}>} [opts.initialRecords]
 *        Pre-loaded events (from a previous process run) to seed the window.
 *
 * Why two-step check/record: the bridge does async chain work between accepting
 * a request and the mint finalizing. A single-call helper would either
 * double-book in-flight requests or fail to record successful ones. Caller
 * pattern is:
 *
 *   const decision = cap.check(amount);
 *   if (!decision.allowed) return 429;
 *   try { await chainWork(); cap.record(amount); } catch { /* not recorded *\/ }
 */
export function createDailyCap(opts = {}) {
  const { maxUsd, now = () => Date.now() / 1000, initialRecords = [] } = opts;
  const unlimited = maxUsd === 'unlimited' || maxUsd === Infinity;
  if (!unlimited && !(Number.isFinite(maxUsd) && maxUsd > 0)) {
    throw new Error('createDailyCap: maxUsd must be a positive finite number or "unlimited"');
  }
  // Copy + sort so a malformed input order can't desync prune().
  const mints = initialRecords
    .filter((r) => Number.isFinite(r?.ts) && Number.isFinite(r?.amountUsd) && r.amountUsd > 0)
    .map((r) => ({ ts: r.ts, amountUsd: r.amountUsd }))
    .sort((a, b) => a.ts - b.ts);

  function prune() {
    if (unlimited || mints.length === 0) return;
    const cutoff = now() - ONE_DAY_SEC;
    while (mints.length && mints[0].ts < cutoff) mints.shift();
  }

  function used() {
    prune();
    let total = 0;
    for (const m of mints) total += m.amountUsd;
    return total;
  }

  return {
    /**
     * Append a successful mint. Returns the new 24h total.
     * Should be called *after* the on-chain mint succeeds so a failed mint
     * does not consume cap headroom.
     */
    record(amountUsd) {
      if (!(Number.isFinite(amountUsd) && amountUsd >= 0)) {
        throw new Error('record: amountUsd must be a non-negative finite number');
      }
      mints.push({ ts: now(), amountUsd });
      return used();
    },

    /**
     * Decide whether `amountUsd` can be admitted right now. Pure read — does
     * not mutate state, so callers can re-check inside the async path.
     */
    check(amountUsd) {
      if (unlimited) {
        return { allowed: true, used: 0, remaining: Infinity, maxUsd: 'unlimited' };
      }
      if (!(Number.isFinite(amountUsd) && amountUsd > 0)) {
        return { allowed: false, reason: 'invalid amount', used: used(), maxUsd };
      }
      const u = used();
      if (u + amountUsd > maxUsd) {
        return {
          allowed: false,
          reason: 'daily cap exceeded',
          used: u,
          remaining: Math.max(0, maxUsd - u),
          would: u + amountUsd,
          maxUsd,
        };
      }
      return { allowed: true, used: u, remaining: maxUsd - u, maxUsd };
    },

    used,
    size() { prune(); return mints.length; },
    reset() { mints.length = 0; },
  };
}

/**
 * Per-source 1-minute sliding-window rate limiter.
 *
 * @param {object} opts
 * @param {number|"unlimited"} opts.maxPerMinute  Hard cap per id per 60s window.
 * @param {() => number} [opts.now]               Seconds-since-epoch source.
 *
 * Why per-IP not per-API-key: rate limiting here is about *work amplification*
 * (don't let a flood of unsigned bodies amplify HMAC cost), not authorization.
 * Authorization is the signature check downstream. An operator behind a real
 * reverse proxy should pass a trusted X-Forwarded-For-derived id instead of
 * the socket address.
 */
export function createRateLimiter(opts = {}) {
  const { maxPerMinute, now = () => Date.now() / 1000 } = opts;
  const unlimited = maxPerMinute === 'unlimited' || maxPerMinute === Infinity;
  if (!unlimited && !(Number.isInteger(maxPerMinute) && maxPerMinute > 0)) {
    throw new Error('createRateLimiter: maxPerMinute must be a positive integer or "unlimited"');
  }
  const buckets = new Map(); // id → [timestamps]

  function prune(arr) {
    const cutoff = now() - ONE_MINUTE_SEC;
    while (arr.length && arr[0] < cutoff) arr.shift();
  }

  return {
    /**
     * Try to admit one request from `id`. Returns `{ allowed, count, retryAfter? }`.
     * `retryAfter` is in seconds; bridge maps it to HTTP `Retry-After`.
     */
    check(id) {
      if (unlimited) return { allowed: true, count: 0, maxPerMinute: 'unlimited' };
      const key = String(id || 'unknown');
      let arr = buckets.get(key);
      if (!arr) { arr = []; buckets.set(key, arr); }
      prune(arr);
      if (arr.length >= maxPerMinute) {
        const retryAfter = Math.max(1, Math.ceil(ONE_MINUTE_SEC - (now() - arr[0])));
        return { allowed: false, count: arr.length, maxPerMinute, retryAfter };
      }
      arr.push(now());
      return { allowed: true, count: arr.length, maxPerMinute };
    },
    size() { return buckets.size; },
    pruneAll() {
      for (const [id, arr] of buckets) {
        prune(arr);
        if (arr.length === 0) buckets.delete(id);
      }
    },
    reset() { buckets.clear(); },
  };
}

/**
 * Replay durable `finalizeStripeEvent` records into a daily-cap seed array.
 *
 * The on-ramp's idempotency layer already writes `{ status, amountSsUsd,
 * processedAt }` per event under `.run/stripe-events/`. Re-reading those on
 * startup keeps the 24h cap honest across restarts; without this, a bridge
 * crash-restart would reset the window and bypass the cap.
 *
 * Returns `[]` if `dir` is missing or unreadable; the cap then just starts
 * empty (still fail-closed once today's mints accumulate in-process).
 */
export function loadOnRampRecords(dir, { now = () => Date.now() / 1000 } = {}) {
  if (!dir || !fs.existsSync(dir)) return [];
  const cutoff = now() - ONE_DAY_SEC;
  const out = [];
  let entries;
  try { entries = fs.readdirSync(dir); } catch { return []; }
  for (const file of entries) {
    if (!file.endsWith('.json')) continue;
    try {
      const data = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf-8'));
      if (data?.status !== 'processed') continue;
      const tsMs = Date.parse(data.processedAt || '');
      if (!Number.isFinite(tsMs)) continue;
      const ts = tsMs / 1000;
      if (ts < cutoff) continue;
      const amountUsd = Number(data.amountSsUsd);
      if (!Number.isFinite(amountUsd) || amountUsd <= 0) continue;
      out.push({ ts, amountUsd });
    } catch {
      // unparseable file — skip; the next mint that lands will write a clean record
    }
  }
  return out;
}

/**
 * Replay durable `finalizePayoutNonce` records into a daily-cap seed array.
 *
 * The off-ramp stores `pull_amount_ssdc_units` (18-decimal ssUSD wei) under
 * `.run/payout-nonces/<seller>/<nonce>.json`. ssUSD is pegged $1 at NAV 1.00,
 * so the wei-to-USD conversion is a straight 1e18 divide; we accept the small
 * NAV-drift error because the daily cap is intentionally coarse-grained.
 */
export function loadOffRampRecords(dir, { now = () => Date.now() / 1000 } = {}) {
  if (!dir || !fs.existsSync(dir)) return [];
  const cutoff = now() - ONE_DAY_SEC;
  const out = [];
  let sellerDirs;
  try { sellerDirs = fs.readdirSync(dir); } catch { return []; }
  for (const sellerDir of sellerDirs) {
    const sub = path.join(dir, sellerDir);
    let stat;
    try { stat = fs.statSync(sub); } catch { continue; }
    if (!stat.isDirectory()) continue;
    let files;
    try { files = fs.readdirSync(sub); } catch { continue; }
    for (const file of files) {
      if (!file.endsWith('.json')) continue;
      try {
        const data = JSON.parse(fs.readFileSync(path.join(sub, file), 'utf-8'));
        if (data?.status !== 'processed') continue;
        const tsMs = Date.parse(data.processedAt || '');
        if (!Number.isFinite(tsMs)) continue;
        const ts = tsMs / 1000;
        if (ts < cutoff) continue;
        // Convert 18dp ssUSD wei → USD-equivalent float via BigInt split to
        // dodge Number-precision loss for treasury-sized amounts.
        const wei = BigInt(String(data.amountSsdcUnits || '0'));
        if (wei <= 0n) continue;
        const whole = Number(wei / 10n ** 18n);
        const frac = Number(wei % 10n ** 18n) / 1e18;
        const amountUsd = whole + frac;
        if (amountUsd <= 0) continue;
        out.push({ ts, amountUsd });
      } catch {
        // skip — see on-ramp loader
      }
    }
  }
  return out;
}

/**
 * Extract a stable per-source key from a Node http request. Uses the trusted
 * X-Forwarded-For-derived address when `trustedProxy` is set (operator opts
 * in); otherwise the raw socket peer.
 *
 * Why opt-in: spoofed X-Forwarded-For from an untrusted client would let a
 * single attacker rotate "source IPs" and bypass per-IP limits. Default to
 * the socket peer; flip `BRIDGE_TRUST_PROXY=1` when sitting behind a known
 * reverse proxy that overwrites the header.
 */
export function clientIdFromRequest(req, { trustProxy = false } = {}) {
  if (trustProxy) {
    const xff = req?.headers?.['x-forwarded-for'];
    if (typeof xff === 'string' && xff.length > 0) {
      // Take the *first* address — the original client; downstream proxies append.
      const first = xff.split(',')[0]?.trim();
      if (first) return first;
    }
  }
  return req?.socket?.remoteAddress || 'unknown';
}
