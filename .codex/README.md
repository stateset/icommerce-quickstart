# .codex — OpenAI Codex CLI project config

Codex CLI auto-loads `config.toml` and `AGENTS.md` from this directory when
invoked from the repo root.

- [`config.toml`](./config.toml) — approval mode, preferred model, suggested
  commands, default refs.
- [`AGENTS.md`](./AGENTS.md) — Codex-flavored project context: repo shape,
  conventions, available agent workflows.
- The harness-neutral workflow definitions live in
  [`../.agents/`](../.agents/) — they read identically from Codex, Claude
  Code, or any other agentic CLI.

## First-time setup

```bash
# Install Codex CLI (one-time, system-wide)
npm install -g @openai/codex

# Verify Codex picks up the project config
cd /path/to/icommerce-quickstart
codex --print-config | head -20
```

## Running a workflow

```bash
# Drop one of the .agents/*.md prompts into a Codex session:
codex --prompt-file .agents/gate-runner.md
codex --prompt-file .agents/release-prep.md
```

…or invoke them by hand: `codex` → paste the markdown body → go.
