# .agents — project-local agent specs

Harness-agnostic prompts for the workflows this repo gets asked to run most
often. Drop each one into any agentic CLI (Claude Code, Codex CLI, OpenCode,
Cursor) — they read as instructions, not as code.

| File | What it does |
|---|---|
| [`gate-runner.md`](./gate-runner.md) | Runs the 5 non-chain CI gates locally; reports failures with the same format as a PR review. |
| [`release-prep.md`](./release-prep.md) | Walks through a release: tag selection, CHANGELOG drafting, preflight checks, dry-run, publish. |
| [`security-reviewer.md`](./security-reviewer.md) | Reviews a branch's diff against [`docs/THREAT_MODEL.md`](../docs/THREAT_MODEL.md); flags new attack surface or weakened mitigations. |
| [`bridge-debugger.md`](./bridge-debugger.md) | Triage flow for a failing bridge — env, idempotency dir, rate limits, FX freshness, allowance state. |
| [`onchain-auditor.md`](./onchain-auditor.md) | Reconstructs a receipt's claims from chain data alone — schema, registry commitment, optional STARK verify. |

## Convention

Each file is a self-contained markdown prompt. Frontmatter is optional —
when present, it matches the Claude Code agent format (`name`, `description`,
`tools`). The body is what gets sent to the agent harness.

For Claude Code, these can be loaded as subagents via `.claude/agents/`
(symlink or copy). For Codex CLI, see [`../.codex/`](../.codex/).

## Adding a new agent

Keep it tight:

1. State the goal in one sentence.
2. List the *exact* commands or files the agent should touch.
3. Specify the report shape — what should come back, in what format.
4. Note what's out of scope (so the agent doesn't drift into unrelated work).

A good agent file is closer to a runbook than a system prompt.
