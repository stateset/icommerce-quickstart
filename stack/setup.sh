#!/usr/bin/env bash
# setup.sh — first-time setup for a fresh clone.
#
# Installs Solidity dependencies (forge install) + Node deps (npm install
# for both bridges/ and demos/). Run once after `git clone`; afterwards
# `./stack/stateset up` is enough.
#
#   bash stack/setup.sh

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -t 1 ]; then G=$'\033[32m'; C=$'\033[36m'; D=$'\033[2m'; B=$'\033[1m'; X=$'\033[0m'
else G= C= D= B= X=; fi

echo -e "${B}icommerce-quickstart setup${X} ${D}— installing Solidity + Node deps${X}\n"

# ─── Solidity: pinned OZ to keep solc 0.8.20 happy ────────────────────────
cd "$ROOT/contracts"
if [ ! -d lib/forge-std ]; then
  echo -e "${C}→${X} forge install foundry-rs/forge-std"
  forge install foundry-rs/forge-std
fi
if [ ! -d lib/openzeppelin-contracts ]; then
  echo -e "${C}→${X} forge install OpenZeppelin/openzeppelin-contracts@v5.0.0"
  forge install "OpenZeppelin/openzeppelin-contracts@v5.0.0"
fi
if [ ! -d lib/openzeppelin-contracts-upgradeable ]; then
  echo -e "${C}→${X} forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.0.0"
  forge install "OpenZeppelin/openzeppelin-contracts-upgradeable@v5.0.0"
fi
echo -e "${G}✓${X} contracts/lib ready ($(ls lib/ | wc -l | tr -d ' ') libs)"

# ─── Node deps ───────────────────────────────────────────────────────────
for pkg in bridges demos; do
  cd "$ROOT/$pkg"
  if [ ! -d node_modules ]; then
    echo -e "${C}→${X} npm install in $pkg/"
    npm install --silent
  fi
done
echo -e "${G}✓${X} bridges/ + demos/ npm deps installed"

echo -e "\n${G}${B}✓ setup complete${X}"
echo -e "  Next: ${B}./stack/stateset up${X}    (start anvil + deploy + bridges)"
echo -e "        ${B}./stack/stateset test${X}  (forge test + bridge tests + demo syntax)"
