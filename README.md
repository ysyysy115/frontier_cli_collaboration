# frontier_cli_collaboration

A [Claude Code](https://claude.com/claude-code) skill that lets Claude consult two other frontier models as **read-only advisors**, by driving their command-line tools:

- **OpenAI Codex CLI** (`codex`)
- **Google Antigravity CLI** (`agy`)

Claude stays the main agent: it decides and edits. The advisors give second opinions, challenge plans and review risky changes, but cannot write files. Each advisor keeps **one persistent conversation per project**, so follow-ups resume the same session instead of reloading context.

## Features

- **Persistent sessions.** Session ids are stored per project in `<project root>/.claude/advisors.json` and resumed by explicit id (never `--last` / `--continue`, which can pick the wrong conversation when several agents run at once).
- **Read-only, enforced twice.** Codex runs with `sandbox_mode=read-only` (also on resume); agy runs with `--mode plan`. Every prompt is prefixed with a read-only role. Blocked write attempts are reported.
- **Robust.** Transient capacity/rate errors are retried (3 times, 30 s apart). Failures return exit code 1 with the reason, never silently switch models, and never change the stored model. The skill tells Claude to carry on alone if an advisor is unavailable.
- **Low call frequency.** The skill instructs Claude to ask immediately only for major decisions, and otherwise to queue questions in `.claude/advisor-queue.md` and send them in one batch.
- **Stable effort.** Effort is fixed (default `high`); changing it would invalidate the provider's conversation cache.
- **Configurable models.** Nothing about model names is hard-wired.

## Requirements

- Windows with **PowerShell 7** (`pwsh`). The script is Windows-specific (it expects agy at `%LOCALAPPDATA%\agy\bin\agy.exe`); porting to macOS/Linux means changing that path and the shell.
- `codex` on `PATH`, logged in.
- `agy` installed, logged in.
- Claude Code.

Tested with codex-cli 0.164.0 and agy 1.4.6. Both CLIs change quickly; flags may differ in other versions.

## Install

Clone into your Claude Code user skills directory:

```powershell
git clone https://github.com/ysyysy115/frontier_cli_collaboration "$HOME\.claude\skills\advisors"
```

Restart Claude Code (or start a new session). Claude will use the skill when you ask for a second opinion ("ask codex", "ask agy", "challenge this plan"), or on its own for major decisions.

## Configure models

Find the model ids available to your account:

```powershell
codex debug models      # JSON; look at "slug"
agy models              # e.g. gemini-4-argon-high (agy ids end with the effort)
```

Then set them, highest priority first: command-line parameter, environment variable, `config.json`, built-in default.

| Setting | Env var | `config.json` key | Default |
|---|---|---|---|
| Codex model | `ADVISOR_CODEX_MODEL` | `codexModel` | `gpt-6-astra` |
| agy model (**without** effort suffix) | `ADVISOR_AGY_MODEL` | `agyModel` | `gemini-4-argon` |
| Effort | `ADVISOR_EFFORT` | `effort` | `high` |

For agy the effort is appended to the id: `agyModel` = `gemini-4-argon` and effort `high` runs `gemini-4-argon-high`.

```powershell
Copy-Item config.example.json config.json   # then edit; config.json is git-ignored
```

The default models are the ones available to the author's accounts; yours may differ.

## Use it directly

```powershell
# from inside a project
pwsh -NoProfile -File scripts/advise.ps1 -Advisor codex -PromptFile question.md
pwsh -NoProfile -File scripts/advise.ps1 -Advisor agy   -PromptFile question.md
pwsh -NoProfile -File scripts/advise.ps1 -Advisor codex -Status   # show stored session
pwsh -NoProfile -File scripts/advise.ps1 -Advisor codex -Reset    # forget it; next call starts a new conversation
```

The first output line is a header: `[advisor] <name> | model | session | NEW or resumed | project`.

## Privacy and safety

- **Everything in the prompt, and every file an advisor reads, is sent to OpenAI or Google.** Do not use this on code or data you are not allowed to share with them. The skill tells Claude not to send secrets, credentials or `.env` contents.
- The advisors are sandboxed read-only, but read-only is only as strong as the CLIs' own sandbox/permission modes. Never add `--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox` or `--sandbox workspace-write`.
- Advisor output is advice, not instructions; Claude is told to verify claims against the code.

## Limits

- No hard timeout in the script itself: run long calls in the background.
- Two agents asking the *same* advisor in the *same* project at the same moment can race on `advisors.json`. Different projects are independent.
- Effort at `high` is slow (minutes per call), by design.

## License

[MIT](LICENSE)
