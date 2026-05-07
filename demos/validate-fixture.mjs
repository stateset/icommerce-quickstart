#!/usr/bin/env node
/**
 * validate-fixture.mjs — JSON Schema validation of a receipt against the
 * schemas in this repo. No chain access needed; runs in milliseconds.
 *
 * Used by CI to ensure `fixtures/agent-receipt.json` stays a valid sample of
 * the `stateset.agent-receipt.v1` schema across schema evolution. Catches
 * schema-vs-fixture drift the moment it lands in a PR.
 *
 *   node validate-fixture.mjs                        # validates the bundled fixture
 *   node validate-fixture.mjs path/to/receipt.json   # validates any receipt
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import Ajv from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const __here = dirname(fileURLToPath(import.meta.url));
const SCHEMAS_DIR = resolve(__here, '../schemas');

const path = process.argv[2] || resolve(__here, 'fixtures/agent-receipt.json');
const receipt = JSON.parse(readFileSync(path, 'utf-8'));

if (typeof receipt.schema !== 'string' || !receipt.schema.startsWith('stateset.')) {
  console.error(`✗ ${path} has no valid \`schema\` field`);
  process.exit(1);
}

// schema id is `stateset.<name>.v<n>` → file is `<name>.v<n>.schema.json`
const schemaName = receipt.schema.split('.').slice(1).join('.');
const schemaPath = resolve(SCHEMAS_DIR, `${schemaName}.schema.json`);
const schema = JSON.parse(readFileSync(schemaPath, 'utf-8'));

const ajv = new Ajv({ allErrors: true, strict: false });
addFormats(ajv);
const validate = ajv.compile(schema);

if (!validate(receipt)) {
  console.error(`✗ ${path} fails ${schemaName} schema:`);
  for (const err of validate.errors) {
    console.error(`    ${err.instancePath || '/'} ${err.message}`);
  }
  process.exit(1);
}

console.log(`✓ ${path} is a valid ${schemaName}`);
