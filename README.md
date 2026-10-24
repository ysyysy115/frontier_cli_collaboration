# frontier_cli_collaboration

A [Claude Code](https://claude.com/claude-code) skill that gives Claude two frontier-model collaborators, driven through their own agent CLIs:

- **OpenAI Codex CLI** (`codex`)
- **Google Antigravity CLI** (`agy`, Gemini Argon)

Claude stays the main agent: it owns the code, decides and integrates. The collaborators explore the repository on their own, so no human has to relay context between models. They give **independent perspectives**, so the human-plus-Claude pair does not settle into a local optimum: independent approaches before committing, red-teaming of plans and results, and experiments delegated to run in parallel.

## Collaborators

| Name | Default model | Role | Can | Writes |
|---|---|---|---|---|
| `codex` | `gpt-6-astra`, high | Opinions, review, critique | Read the repo, run commands, network | Only `.claude/collab/work/` (sandbox) |
| `codex-run` | `gpt-6.1-sol`, medium | Executes delegated tasks: experiments, reproductions, checks. Faster and cheaper. | Same | Same |
| `agy` | `gemini-4-argon`, high | Opinions: method critique, theory, experiment design | Read the repo, reason | Nothing (`--mode plan`) |

Neither collaborator edits the main code; that is Claude's domain, which avoids concurrent edits. Code proposals arrive as patch files that Claude reviews. Each name is **its own persistent conversation per project**, with a fixed model and effort: switching inside a conversation would invalidate the provider's prompt cache.

## Features

- **Persistent sessions** per project (`<root>/.claude/collab/sessions.json`), resumed by explicit id.
- **Hard boundaries.** Codex runs in the `workspace-write` sandbox with its workspace set to `.claude/collab/work/`. agy runs in plan mode. An optional `-Yolo` (for `codex-run` only) removes the sandbox for one call, for the rare check the sandbox blocks; the script then reports any repository change made outside `.claude/collab`.
- **Quota-aware.** Reads quotas before calls (`agy -p /usage` is free; Codex limits come from its session logs). When Argon's weekly quota drops to 15%, it is reserved for major decisions (`-Major`). At 5% it is switched off until reset, and a Gemini Flash fallback runs in a separate conversation, labelled *reference-only*.
- **Robust.** Hard timeout with process-tree kill (default 45 min); retries for capacity errors only; clear exit codes; one call per agent per project at a time (lock). Claude is told to carry on alone whenever a collaborator fails.
- **Reports saved.** Every answer is written to `.claude/collab/reports/`, so results survive Claude's own context compaction. `.claude/collab/` git-ignores itself.

## Requirements

- Windows with **PowerShell 7** (`pwsh`). agy is expected at `%LOCALAPPDATA%\agy\bin\agy.exe`. Porting to macOS/Linux means changing that path and the shell.
- `codex` on `PATH`, logged in; `agy` installed, logged in; Claude Code.
- Tested with codex-cli 0.164.0 and agy 1.4.7. Both CLIs change quickly.

### Windows: let the Codex sandbox run your Python

The Codex Windows sandbox (`elevated`) runs commands as members of the local group `CodexSandboxUsers`, which cannot read `%LOCALAPPDATA%` by default. If your Python lives there (e.g. Anaconda), grant read/execute (not write) once. It can take a long time on a large install:

```powershell
icacls "$env:LOCALAPPDATA\anaconda3" /grant "CodexSandboxUsers:(OI)(CI)RX" /T /C /Q
```

## Install

```powershell
git clone https://github.com/ysyysy115/frontier_cli_collaboration "$HOME\.claude\skills\advisors"
```

Restart Claude Code or open a new session. Claude uses the skill on its own at the right moments (see `SKILL.md`), or when you ask ("ask codex", "ask agy", "get a second opinion").

## Configure

Find the model ids available to your account with `codex debug models` and `agy models`. Settings resolve in this order: environment variable, then `config.json` (copy `config.example.json`; it is git-ignored), then the built-in default.

| Setting | Env var | `config.json` | Default |
|---|---|---|---|
| Codex opinion model | `COLLAB_CODEX_MODEL` | `codexModel` | `gpt-6-astra` |
| Codex task model | `COLLAB_CODEX_RUN_MODEL` | `codexRunModel` | `gpt-6.1-sol` |
| Codex task effort | `COLLAB_CODEX_RUN_EFFORT` | `codexRunEffort` | `medium` |
| agy model (no effort suffix) | `COLLAB_AGY_MODEL` | `agyModel` | `gemini-4-argon` |
| agy fallback model | `COLLAB_AGY_FALLBACK` | `agyFallbackModel` | `gemini-3.8-flash` |
| Effort (codex, agy) | `COLLAB_EFFORT` | `effort` | `high` |
| Argon reserve / stop thresholds | `COLLAB_ARGON_RESERVE` / `COLLAB_ARGON_STOP` | `argonReserve` / `argonStop` | `0.15` / `0.05` |
| Codex network | `COLLAB_CODEX_NETWORK` | `codexNetwork` | `true` |
| Timeout (minutes) | `COLLAB_TIMEOUT_MINUTES` | `timeoutMinutes` | `45` |
| Python for Codex | `COLLAB_PYTHON` | `python` | `python` found on `PATH` |

The defaults are the models available to the author's accounts; yours may differ.

## Direct use

```powershell
# from inside a project
pwsh -NoProfile -File scripts/advise.ps1 -Agent codex     -PromptFile question.md
pwsh -NoProfile -File scripts/advise.ps1 -Agent codex-run -PromptFile task.md
pwsh -NoProfile -File scripts/advise.ps1 -Agent agy       -PromptFile question.md [-Major]
pwsh -NoProfile -File scripts/advise.ps1 -Status                  # sessions, quotas, context use
pwsh -NoProfile -File scripts/advise.ps1 -Agent agy -Compact      # compact the agy conversation
pwsh -NoProfile -File scripts/advise.ps1 -Agent codex -Reset      # forget a session
```

Exit codes: `0` ok, `1` failed, `2` busy, `3` Argon quota reserved, `124` timeout.

## Privacy and safety

- **Everything the collaborators read is sent to OpenAI or Google.** Do not use this on code or data you may not share with them, and keep secrets out of the repository.
- Never pass `--dangerously-skip-permissions` to agy: in testing, its file tool then wrote outside the workspace.
- With `-Yolo`, Codex runs unsandboxed; the write boundary is then only a prompt rule plus the after-the-fact change report.
- Collaborator output is advice. Claude is instructed to verify claims and review patches before applying them.

## License

[MIT](LICENSE)
