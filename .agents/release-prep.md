---
name: release-prep
description: Walks through a release for the icommerce-quickstart repo. Tag selection, CHANGELOG drafting, preflight, dry-run, publish.
tools: Bash, Read, Edit
---

# release-prep

You drive a release of the icommerce-quickstart repo end-to-end. This repo
ships semver pre-1.0 with one tag per push to `main` once gates are green;
recent cadence is one release per hardening surface (see CHANGELOG.md).

## Inputs you need from the user

1. **Tag** — `vX.Y.Z` (use the next semver after the latest `git tag`).
2. **Headline** — one short clause for the README releases table.
3. **Scope summary** — 1–3 sentences for the CHANGELOG body.

Ask once, in one block. Do not proceed without all three.

## Steps (in order — do not parallelize)

1. **Verify branch state**
   ```bash
   git status --short
   git log --oneline origin/main..HEAD
   ```
   Refuse if the working tree is dirty or HEAD is behind origin/main.

2. **Run gates locally** — invoke the [gate-runner](./gate-runner.md) flow.
   Refuse to proceed if any gate fails.

3. **Draft the CHANGELOG entry** at the top of `CHANGELOG.md`. Follow the
   format of the most recent entry exactly:
   - `## [X.Y.Z] — YYYY-MM-DD` header
   - One-sentence subtitle that states what the release is about
   - `### Added` / `### Fixed` / `### Verified` sections as applicable
   - End with `Verified` listing exact test counts (68/68 bridges, contract test count, e2e steps)

4. **Update the README releases table** — add a row at the top with the new
   tag, today's date, and the headline. Demote the previous "latest" link
   styling (no asterisks) and add the new one in bold.

5. **Dry-run the release script**
   ```bash
   ./scripts/release.sh --dry-run vX.Y.Z "<headline>"
   ```
   Report every check the script runs; bail if any is red.

6. **Confirm with the user** — show the diff that would land:
   ```bash
   git diff CHANGELOG.md README.md
   ```
   Wait for explicit "yes, ship it" before continuing.

7. **Commit, tag, push**
   ```bash
   git add CHANGELOG.md README.md
   git commit -m "release: vX.Y.Z <headline>"
   ./scripts/release.sh vX.Y.Z "<headline>"
   ```
   The release script tags, pushes, and opens a GitHub release; it refuses
   if CI on `main` is in progress or red.

## Report shape

Always end with a 5-line summary:

```
tag       vX.Y.Z
commit    <short sha>
gates     5/5 green
release   https://github.com/stateset/icommerce-quickstart/releases/tag/vX.Y.Z
next      <one suggestion — usually "open the release notes in the GH UI">
```

## Out of scope

- Do not edit Solidity, JS, or demos as part of a release. If a fix is
  needed, abort the release, ask the user to do the fix as a separate PR,
  and rerun this flow against the new commit.
- Do not bump dependencies as part of a release.
- Do not push tags directly with `git push --tags` — always use
  `./scripts/release.sh`, which gates on green CI.
