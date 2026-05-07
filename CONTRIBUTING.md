# Contributing

Thanks for considering a contribution to `icommerce-quickstart`. This repo is intentionally narrow: it's the runnable subset of the StateSet iCommerce protocol, not the full platform. PRs that fit the scope below are very welcome.

## In scope

- Bug fixes anywhere
- Improvements to the `stack/stateset` orchestrator (clearer output, more `doctor` checks, better error messages)
- Additional demos that use only `ethers` + the deployed contracts (no monorepo deps)
- Additional contract tests (Foundry)
- Additional bridge unit tests (`node --test`)
- Documentation improvements
- CI improvements
- New supported off-ramp / on-ramp currencies (need a quote source for `<CUR>/ssUSD`)

## Out of scope

These belong upstream in the [`stateset/icommerce-app`](https://github.com/stateset/icommerce-app) monorepo:

- The sequencer (Rust)
- The MCP tooling
- The admin UI (Next.js)
- The receipt-producer (depends on the sequencer + sync engine)
- The `ves-stark` STARK verifier (its own repo: [`stateset/stateset-starks`](https://github.com/stateset/stateset-starks))

If your change crosses those boundaries, please open an issue first to discuss.

## Development

```bash
# Clone + bring up the stack
git clone https://github.com/stateset/icommerce-quickstart && cd icommerce-quickstart
bash stack/setup.sh
./stack/stateset up

# Optional but recommended: install the pre-commit hook
# (runs forge fmt --check + node --check + bash -n on staged files)
bash scripts/install-hooks.sh

# Run all tests (with anvil up)
./stack/stateset test

# Lint contracts (covered by `stateset gates`)
cd contracts && forge fmt --check
cd ..

# Run a specific demo
./stack/stateset demo lifecycle
```

## Before pushing

Two layers of pre-push checks catch failures locally instead of waiting on the 5-minute CI round-trip:

| Layer | Run by | What |
|---|---|---|
| **pre-commit hook** (`bash scripts/install-hooks.sh`) | `git commit` | Per-file: `forge fmt --check` on staged `.sol`, `node --check` on staged `.mjs`, `bash -n` on staged `.sh`. |
| **`./stack/stateset gates`** | manual, before `git push` | Cross-file: `forge fmt --check` + `forge build --sizes` + `forge test` (216) + bridges `npm test` (35) + demos syntax + `validate-fixture`. Mirrors CI's non-chain steps exactly. |

If both pass, your push will land green on contracts + bridges + demos jobs (modulo the e2e steps which need anvil). For the e2e steps, run `./stack/stateset test` with anvil up.

If you're tuning a contract, also run:

```bash
./stack/stateset bench:diff      # see which tests' gas usage moved
./stack/stateset bench:snapshot  # regenerate contracts/.gas-snapshot if intentional
```

Commit the new `.gas-snapshot` alongside the contract change so reviewers can see the gas delta in the PR.

## Pull requests

1. Branch from `main`.
2. Keep changes focused; one PR per logical change.
3. Update `CHANGELOG.md` under `[Unreleased]` if your change is user-visible.
4. Make sure `./stack/stateset gates` passes (and `./stack/stateset test` if you have anvil up).
5. CI must be green before merge.

## Commit messages

- Imperative mood (`Add foo`, not `Added foo` or `Adds foo`).
- First line ≤ 72 chars; blank line; body explaining *why* if non-obvious.
- Reference issues with `#N` if applicable.

## Reporting bugs

Open an issue with:

- Repro steps (what command, what env)
- Expected vs. actual behavior
- Output of `./stack/stateset doctor`

## Security

Do **not** open a public issue for security-relevant findings. Email the maintainers (see GitHub profile) or use a private security advisory on the GitHub repo.
