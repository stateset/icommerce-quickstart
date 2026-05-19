// Tests for bridges/lib/limits.mjs — the daily-cap + rate-limiter primitives
// that close THREAT_MODEL.md's "Bridge layer has no rate limits" item.
//
// Coverage targets:
//   • daily cap admits → records → exhausts → refuses
//   • daily cap rolls off entries older than 24h
//   • daily cap fails closed on bad config (NaN, negative)
//   • daily cap is restart-durable via loadOnRampRecords / loadOffRampRecords
//   • rate limiter admits up to N/min, refuses N+1, then admits after window
//   • rate limiter keys are per-source (independent buckets)
//   • clientIdFromRequest opts in to X-Forwarded-For only when told to
//
// Run:  node --test tests/limits.test.mjs

import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import { join } from 'node:path';

import {
  clientIdFromRequest,
  createDailyCap,
  createRateLimiter,
  loadOffRampRecords,
  loadOnRampRecords,
} from '../lib/limits.mjs';

// ─── createDailyCap ────────────────────────────────────────────────────────

test('daily cap admits below threshold and refuses at threshold', () => {
  let t = 1_000_000;
  const cap = createDailyCap({ maxUsd: 1000, now: () => t });
  assert.equal(cap.check(500).allowed, true);
  cap.record(500);
  assert.equal(cap.used(), 500);

  // Exactly at the cap: 500 used + 500 requested == 1000 — admitted.
  const exact = cap.check(500);
  assert.equal(exact.allowed, true);
  cap.record(500);

  const over = cap.check(1);
  assert.equal(over.allowed, false);
  assert.equal(over.reason, 'daily cap exceeded');
  assert.equal(over.used, 1000);
  assert.equal(over.remaining, 0);
});

test('daily cap rolls off entries older than 24h', () => {
  let t = 1_000_000;
  const cap = createDailyCap({ maxUsd: 1000, now: () => t });
  cap.record(800);
  assert.equal(cap.used(), 800);

  // Advance past 24h — old record should be pruned, headroom restored.
  t += 24 * 60 * 60 + 1;
  assert.equal(cap.used(), 0);
  assert.equal(cap.check(900).allowed, true);
});

test('daily cap with "unlimited" admits everything (escape hatch)', () => {
  const cap = createDailyCap({ maxUsd: 'unlimited' });
  for (let i = 0; i < 10; i++) cap.record(1e9);
  assert.equal(cap.check(1e12).allowed, true);
});

test('daily cap rejects malformed config at construction', () => {
  assert.throws(() => createDailyCap({ maxUsd: -1 }), /must be a positive/);
  assert.throws(() => createDailyCap({ maxUsd: 0 }), /must be a positive/);
  assert.throws(() => createDailyCap({ maxUsd: NaN }), /must be a positive/);
  assert.throws(() => createDailyCap({ maxUsd: 'banana' }), /must be a positive/);
});

test('daily cap rejects malformed amounts at check', () => {
  const cap = createDailyCap({ maxUsd: 100 });
  assert.equal(cap.check(0).allowed, false);
  assert.equal(cap.check(-5).allowed, false);
  assert.equal(cap.check(NaN).allowed, false);
});

test('daily cap seeded with initialRecords reflects historical usage', () => {
  let t = 1_000_000;
  const cap = createDailyCap({
    maxUsd: 1000,
    now: () => t,
    initialRecords: [
      { ts: t - 3600, amountUsd: 700 },          // 1h ago
      { ts: t - 25 * 3600, amountUsd: 500 },     // 25h ago — should be ignored after prune
      { ts: t - 60, amountUsd: 200 },            // 1min ago
    ],
  });
  // 900 used (700 + 200); 25h-old record is older than window, pruned by check.
  assert.equal(cap.used(), 900);
  assert.equal(cap.check(50).allowed, true);
  assert.equal(cap.check(200).allowed, false);   // 900 + 200 > 1000
});

// ─── loadOnRampRecords / loadOffRampRecords ────────────────────────────────

test('loadOnRampRecords parses processed Stripe events and ignores stale ones', () => {
  const dir = fs.mkdtempSync(join(os.tmpdir(), 'stateset-onramp-replay-'));
  try {
    const nowMs = Date.now();
    const recent = new Date(nowMs - 60_000).toISOString();
    const old = new Date(nowMs - 26 * 60 * 60 * 1000).toISOString();
    fs.writeFileSync(join(dir, 'evt_recent.json'), JSON.stringify({
      status: 'processed', amountSsUsd: 250, processedAt: recent,
    }));
    fs.writeFileSync(join(dir, 'evt_old.json'), JSON.stringify({
      status: 'processed', amountSsUsd: 999, processedAt: old,
    }));
    fs.writeFileSync(join(dir, 'evt_failed.json'), JSON.stringify({
      status: 'failed', amountSsUsd: 100, failedAt: recent,
    }));
    fs.writeFileSync(join(dir, 'evt_processing.json'), JSON.stringify({
      status: 'processing', reservedAt: recent,
    }));
    fs.writeFileSync(join(dir, 'evt_garbage.json'), '{ this is not json');

    const records = loadOnRampRecords(dir);
    // Only the recent processed event counts; failed/processing/old/malformed don't.
    assert.equal(records.length, 1);
    assert.equal(records[0].amountUsd, 250);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('loadOnRampRecords returns [] when directory does not exist', () => {
  assert.deepEqual(loadOnRampRecords('/nonexistent/path/xyz'), []);
});

test('loadOffRampRecords converts ssUSD wei to USD and skips stale/non-processed', () => {
  const dir = fs.mkdtempSync(join(os.tmpdir(), 'stateset-offramp-replay-'));
  try {
    const sellerDir = join(dir, '0xseller');
    fs.mkdirSync(sellerDir);
    const recent = new Date(Date.now() - 60_000).toISOString();
    // 1234.5 ssUSD == 1234500000000000000000 wei
    fs.writeFileSync(join(sellerDir, 'nonceA.json'), JSON.stringify({
      status: 'processed', amountSsdcUnits: '1234500000000000000000', processedAt: recent,
    }));
    // failed payout should not count
    fs.writeFileSync(join(sellerDir, 'nonceB.json'), JSON.stringify({
      status: 'failed', amountSsdcUnits: '999000000000000000000', failedAt: recent,
    }));
    // even processed entries with 0 amount are excluded
    fs.writeFileSync(join(sellerDir, 'nonceC.json'), JSON.stringify({
      status: 'processed', amountSsdcUnits: '0', processedAt: recent,
    }));

    const records = loadOffRampRecords(dir);
    assert.equal(records.length, 1);
    // 1234.5 with the fractional split; allow tiny float error.
    assert.ok(Math.abs(records[0].amountUsd - 1234.5) < 1e-9);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('daily cap seeded from loaded records carries usage forward', () => {
  const dir = fs.mkdtempSync(join(os.tmpdir(), 'stateset-restart-'));
  try {
    const recent = new Date(Date.now() - 60_000).toISOString();
    fs.writeFileSync(join(dir, 'evt_a.json'), JSON.stringify({
      status: 'processed', amountSsUsd: 60_000, processedAt: recent,
    }));
    fs.writeFileSync(join(dir, 'evt_b.json'), JSON.stringify({
      status: 'processed', amountSsUsd: 30_000, processedAt: recent,
    }));

    const cap = createDailyCap({
      maxUsd: 100_000,
      initialRecords: loadOnRampRecords(dir),
    });
    assert.equal(cap.used(), 90_000);
    // 90k used, 100k cap: 5k passes, 15k busts the cap.
    assert.equal(cap.check(5000).allowed, true);
    assert.equal(cap.check(15000).allowed, false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ─── createRateLimiter ─────────────────────────────────────────────────────

test('rate limiter admits up to N per minute then refuses', () => {
  let t = 1_000_000;
  const rl = createRateLimiter({ maxPerMinute: 3, now: () => t });
  assert.equal(rl.check('1.1.1.1').allowed, true);
  assert.equal(rl.check('1.1.1.1').allowed, true);
  assert.equal(rl.check('1.1.1.1').allowed, true);
  const refused = rl.check('1.1.1.1');
  assert.equal(refused.allowed, false);
  assert.equal(refused.count, 3);
  // retryAfter must be in (0, 60] — the first record is current, so ~60s left.
  assert.ok(refused.retryAfter > 0 && refused.retryAfter <= 60);
});

test('rate limiter buckets are per-source', () => {
  let t = 1_000_000;
  const rl = createRateLimiter({ maxPerMinute: 1, now: () => t });
  assert.equal(rl.check('1.1.1.1').allowed, true);
  assert.equal(rl.check('1.1.1.1').allowed, false);
  // Different source — independent budget.
  assert.equal(rl.check('2.2.2.2').allowed, true);
});

test('rate limiter window rolls over after 60s', () => {
  let t = 1_000_000;
  const rl = createRateLimiter({ maxPerMinute: 1, now: () => t });
  assert.equal(rl.check('x').allowed, true);
  assert.equal(rl.check('x').allowed, false);
  t += 61;
  assert.equal(rl.check('x').allowed, true);
});

test('rate limiter rejects malformed config', () => {
  assert.throws(() => createRateLimiter({ maxPerMinute: 0 }), /must be a positive/);
  assert.throws(() => createRateLimiter({ maxPerMinute: -1 }), /must be a positive/);
  assert.throws(() => createRateLimiter({ maxPerMinute: 1.5 }), /must be a positive/);
  assert.throws(() => createRateLimiter({ maxPerMinute: NaN }), /must be a positive/);
});

test('rate limiter "unlimited" admits everything', () => {
  const rl = createRateLimiter({ maxPerMinute: 'unlimited' });
  for (let i = 0; i < 10_000; i++) {
    assert.equal(rl.check('flood').allowed, true);
  }
});

// ─── clientIdFromRequest ───────────────────────────────────────────────────

test('clientIdFromRequest uses socket address by default', () => {
  const req = {
    headers: { 'x-forwarded-for': '9.9.9.9' },
    socket: { remoteAddress: '1.2.3.4' },
  };
  // Default: do NOT trust the header — return socket peer.
  assert.equal(clientIdFromRequest(req), '1.2.3.4');
});

test('clientIdFromRequest respects X-Forwarded-For when trustProxy is set', () => {
  const req = {
    headers: { 'x-forwarded-for': '9.9.9.9, 10.0.0.1' },
    socket: { remoteAddress: '1.2.3.4' },
  };
  // Take FIRST entry (original client) when explicitly told to trust.
  assert.equal(clientIdFromRequest(req, { trustProxy: true }), '9.9.9.9');
});

test('clientIdFromRequest falls back to "unknown" when nothing available', () => {
  assert.equal(clientIdFromRequest({}), 'unknown');
  assert.equal(clientIdFromRequest(null), 'unknown');
});
