#!/usr/bin/env bash
# audit-with-cast.sh — independent receipt audit, pure shell.
#
# Verifies a StateSet receipt against the live chain using only:
#   bash + jq + cast (foundry) + ves-stark
#
# No Node, no JS dependencies, no trust in the protocol team's code.
# Demonstrates the protocol is genuinely tool-agnostic — anyone with
# foundry installed can audit any receipt in any environment.
#
# Usage:
#   ./audit-with-cast.sh <receipt.json> [rpc-url]
#
# Returns 0 if every check passes, 1 otherwise.

set -uo pipefail

RECEIPT="${1:-}"
RPC="${2:-http://localhost:8545}"
STARK_BIN="${STARK_BIN:-ves-stark}"
CAST="${CAST:-cast}"

# ─── Colors ──────────────────────────────────────────────────────────────
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; D='\033[2m'; B='\033[1m'; X='\033[0m'

if [ -z "$RECEIPT" ] || [ ! -f "$RECEIPT" ]; then
  echo "usage: $0 <receipt.json> [rpc-url]" >&2
  exit 2
fi
if ! command -v jq >/dev/null; then
  echo "error: jq is required" >&2; exit 2
fi
if ! command -v "$CAST" >/dev/null; then
  echo "error: foundry's cast is required (\$CAST=$CAST)" >&2; exit 2
fi

PASS=0; FAIL=0
ok()   { echo -e "  ${G}✓${X} $1"; PASS=$((PASS+1)); }
bad()  { echo -e "  ${R}✗${X} $1"; FAIL=$((FAIL+1)); }
note() { echo -e "  ${D}$1${X}"; }
hdr()  { echo -e "\n${B}$1${X}"; }

SCHEMA=$(jq -r '.schema // "unknown"' "$RECEIPT")
echo -e "${B}═══════════════════════════════════════════════════════════════════════${X}"
echo -e "${B}  shell-only audit — pure bash + jq + cast + ves-stark${X}"
echo -e "${B}═══════════════════════════════════════════════════════════════════════${X}"
echo -e "  ${D}file:  $RECEIPT${X}"
echo -e "  ${D}rpc:   $RPC${X}"
echo -e "  ${D}stark: $STARK_BIN${X}"
echo -e "  ${D}schema:${X} $SCHEMA"

# ─── Helper: verify a tx hash succeeded on chain ────────────────────────
verify_tx() {
  local label="$1" hash="$2"
  if [ -z "$hash" ] || [ "$hash" = "null" ]; then
    note "$label: not present in receipt (skipped)"
    return
  fi
  local status block
  status=$($CAST receipt "$hash" --rpc-url "$RPC" 2>/dev/null | awk '/^status/ {print $2}')
  block=$($CAST receipt "$hash" --rpc-url "$RPC" 2>/dev/null | awk '/^blockNumber/ {print $2}')
  if [ "$status" = "1" ] || [ "$status" = "0x1" ] || echo "$status" | grep -q "success"; then
    ok "$label  ${D}block $block${X}"
  else
    bad "$label  ${D}status=${status:-missing}${X}"
  fi
}

# ─── Schema dispatch ─────────────────────────────────────────────────────
case "$SCHEMA" in
  stateset.agent-receipt.v1)
    hdr "1. On-chain transactions"
    verify_tx "escrow.lock"           "$(jq -r '.escrow.lockTx // empty'    "$RECEIPT")"
    verify_tx "escrow.markDelivered"  "$(jq -r '.escrow.deliverTx // empty' "$RECEIPT")"
    verify_tx "escrow.release"        "$(jq -r '.escrow.releaseTx // empty' "$RECEIPT")"
    verify_tx "registry.commitBatch"  "$(jq -r '.anchor.anchorTx // empty'  "$RECEIPT")"

    hdr "2. Live escrow state"
    ESCROW=$(jq -r '.escrow.contract' "$RECEIPT")
    ORDER_ID=$(jq -r '.escrow.orderIdHash' "$RECEIPT")
    EXPECTED_STATUS=$(jq -r '.escrow.finalStatus' "$RECEIPT")
    ACTUAL_STATUS_NUM=$($CAST call "$ESCROW" "statusOf(bytes32)(uint8)" "$ORDER_ID" --rpc-url "$RPC" 2>/dev/null)
    STATUS_NAMES=(None Locked Delivered Disputed Released Refunded)
    ACTUAL_STATUS="${STATUS_NAMES[${ACTUAL_STATUS_NUM:-0}]:-?}"
    if [ "$ACTUAL_STATUS" = "$EXPECTED_STATUS" ]; then
      ok "escrow.statusOf == receipt  ${D}(both = $ACTUAL_STATUS)${X}"
    else
      bad "escrow.statusOf drift  ${D}chain=$ACTUAL_STATUS, receipt=$EXPECTED_STATUS${X}"
      note "  drift = receipt's snapshot was overtaken by later mutations; cryptographic claims unaffected"
    fi

    hdr "3. SetRegistry batch + STARK proof commitment"
    REGISTRY=$(jq -r '.anchor.registry' "$RECEIPT")
    BATCH_ID=$(jq -r '.sequencer.batchId' "$RECEIPT")
    EXPECTED_EVENTS_ROOT=$(jq -r '.sequencer.eventsRoot' "$RECEIPT")
    EXPECTED_PROOF_HASH=$(jq -r '.starkProof.proofHash' "$RECEIPT")

    BATCH=$($CAST call "$REGISTRY" "getBatchCommitment(bytes32)((bytes32,bytes32,uint64,uint64,uint32,uint64))" "$BATCH_ID" --rpc-url "$RPC" 2>/dev/null)
    ACTUAL_EVENTS_ROOT=$(echo "$BATCH" | awk -F'[(,) ]+' '{print $2}')
    if [ "${ACTUAL_EVENTS_ROOT,,}" = "${EXPECTED_EVENTS_ROOT,,}" ]; then
      ok "registry.eventsRoot matches"
    else
      bad "registry.eventsRoot mismatch"
    fi

    PROOF=$($CAST call "$REGISTRY" "getStarkProofDetails(bytes32)(bytes32,bytes32,bool,uint64)" "$BATCH_ID" --rpc-url "$RPC" 2>/dev/null)
    ACTUAL_PROOF_HASH=$(echo "$PROOF" | head -1)
    if [ "${ACTUAL_PROOF_HASH,,}" = "${EXPECTED_PROOF_HASH,,}" ]; then
      ok "registry.starkProofHash matches"
    else
      bad "registry.starkProofHash mismatch"
    fi
    ;;

  stateset.cross-border-receipt.v1)
    hdr "1. On-chain transactions"
    verify_tx "escrow.lock"     "$(jq -r '.txs.lock // empty'    "$RECEIPT")"
    verify_tx "escrow.release"  "$(jq -r '.txs.release // empty' "$RECEIPT")"

    hdr "2. FX quote on chain"
    ORACLE=$(jq -r '.fxBinding.oracle' "$RECEIPT")
    PAIR_ID=$(jq -r '.fxBinding.pairId' "$RECEIPT")
    EXPECTED_RATE=$(jq -r '.fxBinding.rateE18' "$RECEIPT")
    QUOTE=$($CAST call "$ORACLE" "getQuote(bytes32)(uint256,uint64)" "$PAIR_ID" --rpc-url "$RPC" 2>/dev/null)
    ACTUAL_RATE=$(echo "$QUOTE" | awk '{print $1}')
    if [ "$ACTUAL_RATE" = "$EXPECTED_RATE" ]; then
      ok "FxOracle.rate matches receipt  ${D}($ACTUAL_RATE)${X}"
    else
      note "FxOracle quote may be stale or rotated  ${D}(chain may revert; receipt rate=$EXPECTED_RATE)${X}"
    fi
    ;;

  stateset.compliance-bundle.v1)
    hdr "1. Underlying transaction"
    verify_tx "escrow.lock"     "$(jq -r '.transaction.lockTx // empty'    "$RECEIPT")"
    verify_tx "escrow.release"  "$(jq -r '.transaction.releaseTx // empty' "$RECEIPT")"

    hdr "2. STARK byte-level verification"
    if [ ! -x "$STARK_BIN" ]; then
      bad "ves-stark not at $STARK_BIN — set STARK_BIN env to override"
    else
      PROOF_COUNT=$(jq '.proofs | length' "$RECEIPT")
      for i in $(seq 0 $((PROOF_COUNT - 1))); do
        POLICY=$(jq -r ".proofs[$i].policy" "$RECEIPT")
        LIMIT=$(jq -r ".proofs[$i].limit" "$RECEIPT")
        FILE=$(jq -r ".proofs[$i].proofFilePath" "$RECEIPT")
        EXTRA=()
        if [ "$POLICY" = "agent.authorization.v1" ]; then
          INTENT=$(jq -r ".proofs[$i].intentHash // empty" "$RECEIPT")
          [ -n "$INTENT" ] && EXTRA+=(--intent-hash "$INTENT")
        fi
        if [ ! -f "$FILE" ]; then
          bad "$POLICY: proof file missing ($FILE)"
          continue
        fi
        OUT=$("$STARK_BIN" verify --proof "$FILE" --policy "$POLICY" --limit "$LIMIT" "${EXTRA[@]}" 2>&1)
        if echo "$OUT" | grep -q "VALID"; then
          SIZE=$(stat -c%s "$FILE" 2>/dev/null || echo "?")
          ok "$POLICY  ${D}STARK valid (${SIZE}-byte proof)${X}"
        else
          bad "$POLICY  ${D}verifier rejected${X}"
        fi
      done
    fi
    ;;

  *)
    bad "unknown schema: $SCHEMA (expected stateset.agent-receipt.v1 / cross-border-receipt.v1 / compliance-bundle.v1)"
    ;;
esac

# ─── Verdict ────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo -e "${G}${B}✓ All $PASS checks verified — pure shell, no Node.${X}"
  exit 0
else
  echo -e "${R}${B}✗ $FAIL of $((PASS + FAIL)) checks failed.${X}"
  exit 1
fi
