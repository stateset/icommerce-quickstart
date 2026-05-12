// Tests for the off-ramp bridge's signature + replay-protection layer.
// Symmetric to bridge-stripe-to-ssdc.test.mjs (HMAC tests on the on-ramp).
//
// Threat coverage from THREAT_MODEL.md:
//   • Spoofing — forged payout request claiming to be seller
//   • Tampering — modify amount / bank / nonce / chainId after signing
//   • Repudiation — seller can't deny a signed request
//   • Replay — same nonce reused
//   • Cross-chain replay — same signature on a different chainId
//
// Run:  node --test ves-demo/bridge-ssdc-payout.test.mjs

import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import { join } from 'node:path';
import { Wallet } from 'ethers';

import {
  failPayoutNonce,
  finalizePayoutNonce,
  payoutMessage,
  reservePayoutNonce,
  verifyPayoutRequest,
} from '../off-ramp.mjs';

// Fixed test signer (anvil[3]) so signatures are reproducible.
const SELLER_KEY = '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6';
const SELLER_ADDR = '0x90F79bf6EB2c4f870365E785982E1f101E93b906';
const CHAIN_ID = 84532001;
const NOW = 1_700_000_000;
const TTL = 5 * 60;

const seller = new Wallet(SELLER_KEY);

async function makeSignedRequest(overrides = {}) {
  const fields = {
    seller: SELLER_ADDR,
    amountUsd: 200,
    bankLast4: '4242',
    nonce: '0x' + 'a'.repeat(32),
    issuedAt: NOW,
    ...overrides,
  };
  const message = payoutMessage({ ...fields, chainId: CHAIN_ID });
  const signature = await seller.signMessage(message);
  return { ...fields, signature };
}

const baseOpts = (extras = {}) => ({
  chainId: CHAIN_ID,
  now: NOW,
  ttl: TTL,
  nonceStore: new Map(),
  ...extras,
});

// ─── happy path ─────────────────────────────────────────────────────────
test('valid signed request from the correct seller is accepted', async () => {
  const req = await makeSignedRequest();
  const result = verifyPayoutRequest(req, baseOpts());
  assert.equal(result.sellerChecked, SELLER_ADDR);
  assert.ok(result.message.includes('amount:    $200.00 USD'));
});

// ─── tampering (each field independently bound by the signature) ────────
test('tampered amount is rejected — signature does not recover', async () => {
  const req = await makeSignedRequest();
  req.amountUsd = 200_000;  // attacker tries to drain way more than the seller signed
  assert.throws(
    () => verifyPayoutRequest(req, baseOpts()),
    /signature does not recover/,
  );
});

test('tampered bank last4 is rejected', async () => {
  const req = await makeSignedRequest();
  req.bankLast4 = '9999';  // attacker redirects to a different bank
  assert.throws(
    () => verifyPayoutRequest(req, baseOpts()),
    /signature does not recover/,
  );
});

test('tampered nonce is rejected', async () => {
  const req = await makeSignedRequest();
  req.nonce = '0x' + 'b'.repeat(32);
  assert.throws(
    () => verifyPayoutRequest(req, baseOpts()),
    /signature does not recover/,
  );
});

test('tampered seller (different address) is rejected', async () => {
  const req = await makeSignedRequest();
  req.seller = '0x0000000000000000000000000000000000000001';
  assert.throws(
    () => verifyPayoutRequest(req, baseOpts()),
    /signature does not recover/,
  );
});

// ─── cross-chain replay ────────────────────────────────────────────────
test('cross-chain replay is rejected — different chainId fails recovery', async () => {
  const req = await makeSignedRequest();      // signed for chain 84532001
  assert.throws(                              // but verified against chain 1
    () => verifyPayoutRequest(req, baseOpts({ chainId: 1 })),
    /signature does not recover/,
  );
});

// ─── freshness (timestamp window) ──────────────────────────────────────
test('expired request (>5 min old) is rejected before signature check', async () => {
  const req = await makeSignedRequest({ issuedAt: NOW - TTL - 1 });
  assert.throws(
    () => verifyPayoutRequest(req, baseOpts()),
    /request older than/,
  );
});

test('future-timestamped request is rejected', async () => {
  const req = await makeSignedRequest({ issuedAt: NOW + 120 });
  assert.throws(
    () => verifyPayoutRequest(req, baseOpts()),
    /issuedAt is in the future/,
  );
});

// ─── replay (within window) ────────────────────────────────────────────
test('same nonce used twice is rejected on the second submit', async () => {
  const req = await makeSignedRequest();
  const store = new Map();
  // First submit must succeed and the bridge then records the nonce.
  const opts = baseOpts({ nonceStore: store });
  const r = verifyPayoutRequest(req, opts);
  assert.equal(r.sellerChecked, SELLER_ADDR);
  // Simulate the bridge persisting the nonce post-success.
  store.set(SELLER_ADDR.toLowerCase(), new Set([req.nonce]));
  // Second submit with same nonce → reject.
  assert.throws(
    () => verifyPayoutRequest(req, baseOpts({ nonceStore: store })),
    /nonce already used/,
  );
});

test('durable payout nonce reservation blocks concurrent duplicate requests', () => {
  const dir = fs.mkdtempSync(join(os.tmpdir(), 'stateset-payout-nonces-'));
  try {
    const nonce = '0x' + 'd'.repeat(32);
    const first = reservePayoutNonce(SELLER_ADDR, nonce, dir);
    const second = reservePayoutNonce(SELLER_ADDR, nonce, dir);
    assert.equal(first.reserved, true);
    assert.equal(second.reserved, false);
    assert.equal(second.status, 'processing');

    finalizePayoutNonce(SELLER_ADDR, nonce, {
      pull_tx: '0xabc',
      pull_block: 42,
      pull_amount_ssdc_units: '200000000000000000000',
    }, dir);
    const third = reservePayoutNonce(SELLER_ADDR, nonce, dir);
    assert.equal(third.reserved, false);
    assert.equal(third.status, 'processed');

    const stored = JSON.parse(fs.readFileSync(first.file, 'utf-8'));
    assert.equal(stored.status, 'processed');
    assert.equal(stored.pullTx, '0xabc');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('failed payout nonce reservations remain visible as failed duplicates', () => {
  const dir = fs.mkdtempSync(join(os.tmpdir(), 'stateset-payout-nonces-'));
  try {
    const nonce = '0x' + 'e'.repeat(32);
    const first = reservePayoutNonce(SELLER_ADDR, nonce, dir);
    assert.equal(first.reserved, true);

    failPayoutNonce(SELLER_ADDR, nonce, new Error('allowance too low'), dir);
    const second = reservePayoutNonce(SELLER_ADDR, nonce, dir);
    assert.equal(second.reserved, false);
    assert.equal(second.status, 'failed');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('durable payout nonce reservation rejects path traversal shaped nonces', () => {
  const dir = fs.mkdtempSync(join(os.tmpdir(), 'stateset-payout-nonces-'));
  try {
    assert.throws(() => reservePayoutNonce(SELLER_ADDR, '../nonce', dir), /invalid nonce/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('different nonces from same seller are independent', async () => {
  const store = new Map();
  const r1 = await makeSignedRequest({ nonce: '0x' + 'a'.repeat(32) });
  const r2 = await makeSignedRequest({ nonce: '0x' + 'c'.repeat(32) });
  verifyPayoutRequest(r1, baseOpts({ nonceStore: store }));
  store.set(SELLER_ADDR.toLowerCase(), new Set([r1.nonce]));
  // Different nonce → ok
  const ok = verifyPayoutRequest(r2, baseOpts({ nonceStore: store }));
  assert.equal(ok.sellerChecked, SELLER_ADDR);
});

// ─── shape validation ──────────────────────────────────────────────────
test('missing required fields are rejected', async () => {
  for (const field of ['seller', 'amountUsd', 'bankLast4', 'nonce', 'issuedAt', 'signature']) {
    const req = await makeSignedRequest();
    delete req[field];
    assert.throws(
      () => verifyPayoutRequest(req, baseOpts()),
      /missing field/,
      `expected missing-field error when '${field}' is absent`,
    );
  }
});

test('amount below minimum is rejected', async () => {
  const req = await makeSignedRequest({ amountUsd: 0.5 });
  assert.throws(
    () => verifyPayoutRequest(req, baseOpts()),
    /amount must be between/,
  );
});

test('amount above maximum is rejected', async () => {
  const req = await makeSignedRequest({ amountUsd: 100_000_000 });
  assert.throws(
    () => verifyPayoutRequest(req, baseOpts()),
    /amount must be between/,
  );
});

test('bankLast4 must be exactly 4 digits', async () => {
  const req = await makeSignedRequest({ bankLast4: '424' });
  assert.throws(
    () => verifyPayoutRequest(req, baseOpts()),
    /bankLast4 must be 4 digits/,
  );
  const req2 = await makeSignedRequest({ bankLast4: '424A' });
  assert.throws(
    () => verifyPayoutRequest(req2, baseOpts()),
    /bankLast4 must be 4 digits/,
  );
});

// ─── the canonical message format itself ───────────────────────────────
test('payoutMessage includes every binding field on its own line', () => {
  const m = payoutMessage({
    seller: SELLER_ADDR, amountUsd: 200, bankLast4: '4242',
    nonce: '0xnonce', issuedAt: NOW, chainId: CHAIN_ID,
  });
  assert.ok(m.startsWith('StateSet SSDC payout request v1\n'));
  assert.ok(m.includes(`seller:    ${SELLER_ADDR}`));
  assert.ok(m.includes('amount:    $200.00 USD'));
  assert.ok(m.includes('bank:      ****4242'));
  assert.ok(m.includes('nonce:     0xnonce'));
  assert.ok(m.includes(`issuedAt:  ${NOW}`));
  assert.ok(m.includes(`chainId:   ${CHAIN_ID}`));
});

// ─── multi-currency off-ramp ───────────────────────────────────────────
// Symmetric to the on-ramp's 5-currency support. The signature still binds
// every field — including outputCurrency — so a request signed for GBP
// can't be replayed as a USD request even if the numeric amount matches.

test('USD message bytes are identical with and without outputCurrency=USD', () => {
  const a = payoutMessage({
    seller: SELLER_ADDR, amountUsd: 200, bankLast4: '4242',
    nonce: '0xn', issuedAt: NOW, chainId: CHAIN_ID,
  });
  const b = payoutMessage({
    seller: SELLER_ADDR, amountUsd: 200, bankLast4: '4242',
    nonce: '0xn', issuedAt: NOW, chainId: CHAIN_ID, outputCurrency: 'USD',
  });
  assert.equal(a, b);  // backwards-compat: pre-multi-currency signatures still verify
});

test('GBP payout — message format and signature recovery', async () => {
  const fields = {
    seller: SELLER_ADDR, amountUsd: 200, bankLast4: '4242',
    nonce: '0x' + 'g'.repeat(32), issuedAt: NOW, outputCurrency: 'GBP',
  };
  const message = payoutMessage({ ...fields, chainId: CHAIN_ID });
  assert.ok(message.includes('amount:    £200.00 GBP'), `unexpected line in:\n${message}`);
  const signature = await seller.signMessage(message);
  const result = verifyPayoutRequest({ ...fields, signature }, baseOpts());
  assert.equal(result.outputCurrency, 'GBP');
});

test('JPY payout — zero-decimal currencies render as integers', async () => {
  const fields = {
    seller: SELLER_ADDR, amountUsd: 30000, bankLast4: '4242',
    nonce: '0x' + 'j'.repeat(32), issuedAt: NOW, outputCurrency: 'JPY',
  };
  const message = payoutMessage({ ...fields, chainId: CHAIN_ID });
  assert.ok(message.includes('amount:    ¥30000 JPY'), `unexpected line in:\n${message}`);
  // No comma, no decimals — message must be byte-deterministic.
  assert.ok(!message.includes('30,000'));
  assert.ok(!message.includes('30000.00'));
  const signature = await seller.signMessage(message);
  const result = verifyPayoutRequest({ ...fields, signature }, baseOpts());
  assert.equal(result.outputCurrency, 'JPY');
});

test('EUR + MXN payouts round-trip through verify', async () => {
  for (const outputCurrency of ['EUR', 'MXN']) {
    const fields = {
      seller: SELLER_ADDR, amountUsd: 150.5, bankLast4: '4242',
      nonce: '0x' + outputCurrency.charCodeAt(0).toString(16).padStart(2, '0').repeat(16),
      issuedAt: NOW, outputCurrency,
    };
    const message = payoutMessage({ ...fields, chainId: CHAIN_ID });
    const signature = await seller.signMessage(message);
    const result = verifyPayoutRequest({ ...fields, signature }, baseOpts());
    assert.equal(result.outputCurrency, outputCurrency);
  }
});

test('cross-currency replay is rejected — same fields signed for GBP fail USD verify', async () => {
  // Seller signs amount=200 in GBP; attacker submits same { amount, bank,
  // nonce, issuedAt, signature } as a USD payout. Bridge must reject.
  const fields = {
    seller: SELLER_ADDR, amountUsd: 200, bankLast4: '4242',
    nonce: '0x' + 'r'.repeat(32), issuedAt: NOW,
  };
  const gbpMessage = payoutMessage({ ...fields, chainId: CHAIN_ID, outputCurrency: 'GBP' });
  const signature = await seller.signMessage(gbpMessage);
  // Replay as USD (the default) — recovery fails because the message bytes differ.
  assert.throws(
    () => verifyPayoutRequest({ ...fields, signature }, baseOpts()),
    /signature does not recover/,
  );
});

test('unsupported outputCurrency is rejected before signature check', async () => {
  const fields = {
    seller: SELLER_ADDR, amountUsd: 100, bankLast4: '4242',
    nonce: '0x' + 'x'.repeat(32), issuedAt: NOW, outputCurrency: 'XYZ',
  };
  // Doesn't even get to signing — but include a stub signature for shape.
  assert.throws(
    () => verifyPayoutRequest({ ...fields, signature: '0x' + '0'.repeat(130) }, baseOpts()),
    /unsupported outputCurrency XYZ/,
  );
});
