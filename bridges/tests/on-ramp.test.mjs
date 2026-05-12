// Tests for the on-ramp bridge's HMAC signature verification.
// The most security-sensitive code in the entire stack — a bug here would
// let attackers mint SSDC out of thin air. Every threat from THREAT_MODEL.md
// in the "Spoofing → forged Stripe webhook" row should be enforced here.
//
// Run:  node --test ves-demo/bridge-stripe-to-ssdc.test.mjs

import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import { join } from 'node:path';

import {
  failStripeEvent,
  finalizeStripeEvent,
  reserveStripeEvent,
  verifyStripeSignature,
} from '../on-ramp.mjs';

const SECRET = 'whsec_test_for_unit_tests';
const SIGNING_TOLERANCE = 5 * 60;
const NOW = 1_700_000_000;        // fixed test "now" — ~Nov 2023
const BODY = JSON.stringify({ id: 'evt_test_1', type: 'checkout.session.completed' });

function sign(t, body, secret = SECRET) {
  const sig = crypto.createHmac('sha256', secret).update(`${t}.${body}`).digest('hex');
  return `t=${t},v1=${sig}`;
}

test('valid signature with current timestamp is accepted', () => {
  const header = sign(NOW, BODY);
  const r = verifyStripeSignature(BODY, header, SECRET, { now: NOW });
  assert.equal(r.verified, true);
  assert.equal(r.timestamp, NOW);
});

test('valid signature within tolerance window is accepted', () => {
  const header = sign(NOW - 4 * 60, BODY); // 4 min old
  const r = verifyStripeSignature(BODY, header, SECRET, { now: NOW });
  assert.equal(r.verified, true);
});

test('signature past tolerance window is rejected', () => {
  const header = sign(NOW - SIGNING_TOLERANCE - 1, BODY); // 5min1s old
  assert.throws(
    () => verifyStripeSignature(BODY, header, SECRET, { now: NOW }),
    /timestamp outside tolerance/,
  );
});

test('signature timestamped in the future (skew) is rejected', () => {
  const header = sign(NOW + SIGNING_TOLERANCE + 1, BODY); // 5min1s future
  assert.throws(
    () => verifyStripeSignature(BODY, header, SECRET, { now: NOW }),
    /timestamp outside tolerance/,
  );
});

test('wrong secret is rejected', () => {
  const header = sign(NOW, BODY, 'whsec_wrong_secret');
  assert.throws(
    () => verifyStripeSignature(BODY, header, SECRET, { now: NOW }),
    /signature mismatch/,
  );
});

test('tampered body is rejected (CRITICAL — core spoofing defense)', () => {
  const header = sign(NOW, BODY);
  const tamperedBody = BODY.replace('"checkout.session.completed"', '"charge.refunded"');
  assert.throws(
    () => verifyStripeSignature(tamperedBody, header, SECRET, { now: NOW }),
    /signature mismatch/,
  );
});

test('tampered timestamp (with original signature) is rejected', () => {
  const header = sign(NOW, BODY);
  // Forge a header that says t=NOW+10 but keeps the original v1 signature.
  // Since v1 was over `${NOW}.${BODY}`, recomputing with NOW+10 won't match.
  const forged = header.replace(`t=${NOW}`, `t=${NOW + 10}`);
  assert.throws(
    () => verifyStripeSignature(BODY, forged, SECRET, { now: NOW + 10 }),
    /signature mismatch/,
  );
});

test('missing Stripe-Signature header is rejected', () => {
  assert.throws(
    () => verifyStripeSignature(BODY, undefined, SECRET, { now: NOW }),
    /missing Stripe-Signature header/,
  );
});

test('malformed header (no t= or v1=) is rejected', () => {
  assert.throws(
    () => verifyStripeSignature(BODY, 'garbage', SECRET, { now: NOW }),
    /malformed signature header/,
  );
});

test('header with t but no v1 is rejected', () => {
  assert.throws(
    () => verifyStripeSignature(BODY, `t=${NOW}`, SECRET, { now: NOW }),
    /malformed signature header/,
  );
});

test('header with v1 but no t is rejected', () => {
  assert.throws(
    () => verifyStripeSignature(BODY, `v1=${'a'.repeat(64)}`, SECRET, { now: NOW }),
    /malformed signature header/,
  );
});

test('Stripe-style header with extra fields (v0=, scheme=) still validates v1', () => {
  // Real Stripe headers can include multiple version fields; we just need v1.
  const sig = crypto.createHmac('sha256', SECRET).update(`${NOW}.${BODY}`).digest('hex');
  const header = `t=${NOW},v1=${sig},v0=ignored_legacy_field`;
  const r = verifyStripeSignature(BODY, header, SECRET, { now: NOW });
  assert.equal(r.verified, true);
});

test('replay protection requires upstream nonce tracking (this layer is not enough)', () => {
  // Document the boundary: HMAC alone doesn't prevent replay if the same
  // event is delivered twice within the tolerance window. The bridge layer
  // must dedupe on event.id (BRIDGES.md §1.2).
  const header = sign(NOW, BODY);
  const r1 = verifyStripeSignature(BODY, header, SECRET, { now: NOW });
  const r2 = verifyStripeSignature(BODY, header, SECRET, { now: NOW + 60 });
  assert.equal(r1.verified, true);
  assert.equal(r2.verified, true, 'second submit also passes signature check; dedupe is upstream');
});

test('event id reservation blocks duplicate Stripe webhook processing', () => {
  const dir = fs.mkdtempSync(join(os.tmpdir(), 'stateset-stripe-events-'));
  try {
    const first = reserveStripeEvent('evt_duplicate_test', dir);
    const second = reserveStripeEvent('evt_duplicate_test', dir);
    assert.equal(first.reserved, true);
    assert.equal(second.reserved, false);
    assert.equal(second.status, 'processing');

    finalizeStripeEvent('evt_duplicate_test', { txHash: '0xabc', block: 123, buyer: '0x1' }, dir);
    const third = reserveStripeEvent('evt_duplicate_test', dir);
    assert.equal(third.reserved, false);
    assert.equal(third.status, 'processed');

    const stored = JSON.parse(fs.readFileSync(first.file, 'utf-8'));
    assert.equal(stored.status, 'processed');
    assert.equal(stored.txHash, '0xabc');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('failed Stripe event reservations are not treated as processed duplicates', () => {
  const dir = fs.mkdtempSync(join(os.tmpdir(), 'stateset-stripe-events-'));
  try {
    const first = reserveStripeEvent('evt_failed_test', dir);
    assert.equal(first.reserved, true);

    failStripeEvent('evt_failed_test', new Error('rpc temporarily unavailable'), dir);
    const second = reserveStripeEvent('evt_failed_test', dir);
    assert.equal(second.reserved, false);
    assert.equal(second.status, 'failed');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('event id reservation rejects path traversal shaped ids', () => {
  const dir = fs.mkdtempSync(join(os.tmpdir(), 'stateset-stripe-events-'));
  try {
    assert.throws(() => reserveStripeEvent('../evt_escape', dir), /invalid event\.id/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('hex-decoded v1 of wrong length is rejected', () => {
  // timingSafeEqual throws on length mismatch — captured as a generic failure.
  const header = `t=${NOW},v1=deadbeef`; // way too short
  assert.throws(
    () => verifyStripeSignature(BODY, header, SECRET, { now: NOW }),
    /Input buffers must have the same byte length|signature mismatch/,
  );
});
