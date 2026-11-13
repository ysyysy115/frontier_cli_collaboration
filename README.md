# frontier_cli_collaboration

A [Claude Code](https://claude.com/claude-code) skill that gives Claude frontier-model collaborators, driven through their own agent CLIs:

- **OpenAI Codex CLI** (`codex`): GPT-6 Astra for opinions, GPT-6.1 Sol for executing tasks
- **Google Antigravity CLI** (`agy`): Gemini 4 Hydrogen for everyday opinions, Gemini 4 Argon for the hardest questions

Claude stays the main agent: it owns the code, decides and integrates. The collaborators read the repository on their own, so no human has to relay context between models. They give **independent perspectives**, so the human-plus-Claude pair does not settle into a local optimum: independent approaches before committing, red-teaming of plans and results, and experiments delegated to run in parallel.

## Collaborators

| Name | Default model | Role | Can | Writes |
|---|---|---|---|---|
| `codex` | `gpt-6-astra`, high | Opinions, review, critique (frontier) | Read the repo, run commands, network | Only `.claude/collab/work/` (sandbox) |
| `codex-run` | `gpt-6.1-sol`, medium | Executes delegated tasks: experiments, reproductions, checks. Faster and cheaper. | Same | Same |
| `hydrogen` | `gemini-4-hydrogen`, xhigh | Opinions: method critique, theory, plan and document review. Large shared quota, so the everyday Google-side advisor. | Read files | Nothing |
| `agy` (alias `argon`) | `gemini-4-argon`, high | Opinions on the hardest, most consequential questions (frontier). Small separate quota. | Read files | Nothing |

None of the collaborators edits the main code; that is Claude's domain, which avoids concurrent edits. Code proposals arrive as patch files that Claude reviews. Each name is **its own persistent conversation per project**, with a fixed model and effort: switching inside a conversation would invalidate the provider's prompt cache.

## Features

- **Persistent sessions** per project (`<root>/.claude/collab/sessions.json`), resumed by explicit id and shared by every Claude session in that project. `-Thread <name>` opens a separate conversation (with its own lock) for a distinct workstream, for a second independent opinion, or when another session is using the shared one. `-Status` shows each conversation's last request and whether it is busy, so Claude can choose.
- **Hard boundaries.** Codex runs in the `workspace-write` sandbox with its workspace set to `.claude/collab/work/`. agy runs in plan mode (no file writes) with a session-only `deny command(*)` rule, which blocks every shell command, including ones on your global agy allow-list. A denied command comes back to the model as an error instead of ending its turn. An optional `-Yolo` (for `codex-run` only) removes the Codex sandbox for one call, for the rare check the sandbox blocks; the script then reports any repository change made outside `.claude/collab`.
- **File discovery for agy.** Without a shell, agy has `read_file` but no listing or search tool, so the script writes the project's file list to `.claude/collab/files.txt` before each call and points the model to it.
- **Quota-aware.** Reads quotas before calls (`agy -p /usage` is free; Codex limits come from its session logs). Hydrogen draws on the shared Gemini pool; at 10% weekly left it is reserved for major decisions (`-Major`). Argon has its own small weekly quota: at 15% it is reserved for major decisions, and at 5% it is switched off until reset, with Claude pointed to `hydrogen`.
- **Robust.** Hard timeout with process-tree kill (default 45 min); retries for capacity errors only; clear exit codes; one call per conversation at a time (lock). Claude is told to carry on alone whenever a collaborator fails.
- **Reports saved.** Every answer is written to `.claude/collab/reports/`, so results survive Claude's own context compaction. `.claude/collab/` git-ignores itself.

## Requirements

- Windows with **PowerShell 7** (`pwsh`). agy is expected at `%LOCALAPPDATA%\agy\bin\agy.exe`. Porting to macOS/Linux means changing that path and the shell.
- `codex` on `PATH`, logged in; `agy` installed, logged in; Claude Code.
- Tested with codex-cli 0.164.0 and agy 1.5.8. Both CLIs change quickly; see [CHANGELOG.md](CHANGELOG.md).

### Windows: let the Codex sandbox run your Python

The Codex Windows sandbox (`elevated`) runs commands as members of the local group `CodexSandboxUsers`, which cannot read `%LOCALAPPDATA%` by default. If your Python lives there (e.g. Anaconda), grant read/execute (not write) once. It can take a long time on a large install:

```powershell
icacls "$env:LOCALAPPDATA\anaconda3" /grant "CodexSandboxUsers:(OI)(CI)RX" /T /C /Q
```

## Install

```powershell
git clone https://github.com/ysyysy115/frontier_cli_collaboration "$HOME\.claude\skills\advisors"
```

Restart Claude Code or open a new session. Claude uses the skill on its own at the right moments (see `SKILL.md`), or when you ask ("ask codex", "ask hydrogen", "ask argon", "get a second opinion").

## Configure

Find the model ids available to your account with `codex debug models` and `agy models`. Settings resolve in this order: environment variable, then `config.json` (copy `config.example.json`; it is git-ignored), then the built-in default.

| Setting | Env var | `config.json` | Default |
|---|---|---|---|
| Codex opinion model | `COLLAB_CODEX_MODEL` | `codexModel` | `gpt-6-astra` |
| Codex task model | `COLLAB_CODEX_RUN_MODEL` | `codexRunModel` | `gpt-6.1-sol` |
| Codex task effort | `COLLAB_CODEX_RUN_EFFORT` | `codexRunEffort` | `medium` |
| Argon model (no effort suffix) | `COLLAB_AGY_MODEL` | `agyModel` | `gemini-4-argon` |
| Hydrogen model (no effort suffix) | `COLLAB_HYDROGEN_MODEL` | `hydrogenModel` | `gemini-4-hydrogen` |
| Hydrogen effort (up to `xhigh`) | `COLLAB_HYDROGEN_EFFORT` | `hydrogenEffort` | `xhigh` |
| Effort (codex, Argon; Argon is capped at `high`) | `COLLAB_EFFORT` | `effort` | `high` |
| Argon reserve / stop thresholds | `COLLAB_ARGON_RESERVE` / `COLLAB_ARGON_STOP` | `argonReserve` / `argonStop` | `0.15` / `0.05` |
| Shared Gemini pool reserve (Hydrogen) | `COLLAB_GEMINI_RESERVE` | `geminiReserve` | `0.10` |
| Codex network | `COLLAB_CODEX_NETWORK` | `codexNetwork` | `true` |
| Timeout (minutes) | `COLLAB_TIMEOUT_MINUTES` | `timeoutMinutes` | `45` |
| Python for Codex | `COLLAB_PYTHON` | `python` | `python` found on `PATH` |

The defaults are the models available to the author's accounts; yours may differ.

## Direct use

```powershell
# from inside a project
pwsh -NoProfile -File scripts/advise.ps1 -Agent codex     -PromptFile question.md
pwsh -NoProfile -File scripts/advise.ps1 -Agent codex-run -PromptFile task.md
pwsh -NoProfile -File scripts/advise.ps1 -Agent hydrogen  -PromptFile question.md [-Major]
pwsh -NoProfile -File scripts/advise.ps1 -Agent agy       -PromptFile question.md [-Major]
pwsh -NoProfile -File scripts/advise.ps1 -Agent hydrogen -Thread revision-plan -PromptFile q.md   # separate conversation
pwsh -NoProfile -File scripts/advise.ps1 -Status                       # sessions, threads, busy, last request, quotas
pwsh -NoProfile -File scripts/advise.ps1 -Agent hydrogen -Compact      # compact an agy conversation
pwsh -NoProfile -File scripts/advise.ps1 -Agent codex -Reset           # forget a session (add -Thread for a thread)
```

Exit codes: `0` ok, `1` failed, `2` busy, `3` quota reserved or exhausted, `124` timeout.

## Privacy and safety

- **Everything the collaborators read is sent to OpenAI or Google.** Do not use this on code or data you may not share with them, and keep secrets out of the repository.
- Never pass `--dangerously-skip-permissions` to agy: in testing, its file tool then wrote outside the workspace.
- agy honours your global allow-list (`~/.gemini/config/config.json`) even in plan mode; the script's session-only deny rule overrides it. Keep that rule if you change the script.
- With `-Yolo`, Codex runs unsandboxed; the write boundary is then only a prompt rule plus the after-the-fact change report.
- Collaborator output is advice. Claude is instructed to verify claims and review patches before applying them.

## License

[MIT](LICENSE)
