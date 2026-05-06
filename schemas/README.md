# StateSet Receipt Schemas

JSON Schema 2020-12 definitions for the three receipt formats every demo emits. Treat these as the **canonical interop contract** between StateSet and any third party that consumes a receipt — wallets, dashboards, regulators, downstream agents.

## Schemas

| File | `schema` discriminator | Emitted by |
|------|------------------------|------------|
| `agent-receipt.v1.schema.json` | `stateset.agent-receipt.v1` | `agent-receipt.mjs`, `claude-agent-receipt.mjs`, `agent_receipt_purchase` MCP tool |
| `cross-border-receipt.v1.schema.json` | `stateset.cross-border-receipt.v1` | `cross-border-demo.mjs` |
| `compliance-bundle.v1.schema.json` | `stateset.compliance-bundle.v1` | `compliance-bundle-demo.mjs` |

## Two-stage verification

Each receipt should pass two checks before it can be trusted:

1. **Structural validation** — does the receipt match its schema?
   ```bash
   node ves-demo/validate-receipt.mjs <receipt.json>
   node ves-demo/validate-receipt.mjs --all   # every receipt in ves-demo/
   ```

2. **Semantic verification** — do the receipt's claims hold against the live chain (and, for compliance bundles, do the STARK proofs cryptographically verify)?
   ```bash
   node ves-demo/verify-receipt.mjs <receipt.json>
   ```

The MCP tool `agent_receipt_audit` runs the second pass and returns a structured pass/fail summary an agent can act on.

## Versioning

Every schema's top-level `schema` field is a `const` discriminator. Future versions bump the suffix (`stateset.agent-receipt.v2`, etc.) and ship as separate schema files; old versions stay readable forever.

## Address / hash conventions

- All EVM addresses are 20-byte hex with `0x` prefix; **no checksum required** (case-insensitive). Receipt producers are free to checksum-encode for human readability; consumers must lowercase before comparing.
- All transaction hashes and 32-byte commitments are hex-encoded with `0x` prefix.
- Token amounts large enough to overflow JS `Number` are encoded as decimal strings (`"amountUnits": "1697850000"`). Smaller human-readable totals stay as JSON numbers.
