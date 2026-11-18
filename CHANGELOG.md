# Changelog

## 2026-11-17: GPT-6.2

Tested with codex-cli 0.169.1 and agy 1.5.8.

### Changed
- Defaults are now `gpt-6.2-astra` (`codex`, frontier) and `gpt-6.2-sol` (`codex-run`, everyday). They appear in `codex debug models` from codex-cli 0.169; older CLI versions do not list them, so update the CLI or pin the old ids with `COLLAB_CODEX_MODEL` / `COLLAB_CODEX_RUN_MODEL`.
- `codex-run` effort is now `high` (was `medium`); `codex` stays at `high`. The new `max` and `ultra` levels are not used by default.

## 2026-11-15: agy as a full agent; preamble first, backstops second

Tested with codex-cli 0.167.2 and agy 1.5.9 on Windows 11 24H2.

### Why
- In agy 1.5.9, `--mode plan` no longer blocks `write_file`: a probe file was written to the repository. The read-only guarantee the skill relied on was gone.
- The `deny command(*)` rule left agy with `read_file` and `search_web` only: no search, no Python, no git. In 52 reports agy never cited a web source.
- Auto mode is no alternative here: it forces the Windows terminal sandbox, which in testing could not read the user profile, write its own workspace, start Python from `%LOCALAPPDATA%` or pass TLS, and its reviewer approved commands leaving the sandbox.

### Changed
- **agy (`hydrogen`, `agy`) runs as a full agent**: default mode, no terminal sandbox, all commands allowed for the session (`--settings`), launched in `.claude/collab/work/`. It searches the repo (`rg`, read-only git), runs Python and tests, searches the web and fetches pages.
- **New top-level preamble for every agent**, the main control: role; what it can do; the limits (write only in the workspace, never delete, no state-changing git, no installs, no secrets, headless: do not ask, answer within the turn); and how to work (form its own view from primary sources instead of trusting Claude's summary, treat the owner's direction as binding, give constructive alternatives as well as critique, cite evidence). In testing, Hydrogen refused a request to edit, delete and commit on its own.
- **Tiers**: `codex-run` (Sol) and `hydrogen` are the everyday pair, `codex` (Astra) and `agy` (Argon) the frontier pair; all four for major decisions. The `codex-run` role now covers analysis as well as execution.
- SKILL.md: request-writing guidance (briefing as pointers plus the owner's direction in their words, kept current; facts with sources; no anchoring on your own options; ask how to succeed, not only what is wrong; batching rhythm); advisor agreement is input, not a decision; `-Major` only for genuinely major decisions.

### Added
- **Guard hooks for agy** (backstop): `scripts/guard_write.py` lets `write_file`/`edit_file` write only under `work/`; `scripts/guard_cmd.py` blocks deletes, state-changing git (read-only git stays allowed) and package installs. Written to `work/.agents/hooks.json` before each call; fail closed; cover subagents; decisions logged to `.claude/collab/guard-<agent>.log`, and blocked actions are reported in the header.
- **Codex**: web search is enabled explicitly (`-c web_search="live"` with network on) instead of relying on the user's `config.toml`. Codex hooks are disabled for advisor calls (`--disable hooks`; `codexHooks: true` keeps them): rtk's command-rewriting hook made every git and rg command fail inside the Windows sandbox. The preamble tells codex to prefer its web search tool (shell HTTPS downloads fail in the sandbox) and to run commands directly if a wrapper fails.
- **Repository check for every agent** (backstop): the working tree is snapshotted as a git tree object before and after each call, in a temporary copy of the index (the user's index, branches and stash are untouched; untracked files over 20 MB are compared by size and time). Changes and moved refs are reported in the header with a restore command. This replaces the `-Yolo`-only change report.

### Removed
- `--mode plan` and the `deny command(*)` rule for agy.
- `files.txt` (agy can list and search the repo itself now).

## 2026-11-13: Gemini 4 Hydrogen, threads, agy 1.5.8

Tested with codex-cli 0.164.0 and agy 1.5.8.

### Added
- **`hydrogen` collaborator**: Gemini 4 Hydrogen at `xhigh`, its own conversation and lock, read-only like `agy`. It draws on the shared Gemini quota pool (large), so it is the everyday Google-side advisor next to `codex`. Config: `hydrogenModel`, `hydrogenEffort`, `geminiReserve`.
- **`-Thread <name>`**: a separate conversation (`<agent>@<name>`) with its own lock, for a distinct workstream, a second independent opinion, or when another Claude session is using the shared conversation of that project. `-Reset` and `-Compact` take it too.
- **`-Status`** now lists threads, marks conversations with a running call as `BUSY`, and shows each one's `last ask` (the gist of its latest request), so a Claude session can tell whether to reuse the shared conversation.
- **`files.txt`**: before each agy call the script writes the project's file list to `.claude/collab/files.txt` and points the model to it, because agy has no listing or search tool once commands are blocked.
- `-Agent argon` as an alias for `agy`.
- Per-model effort limits: Argon up to `high`, Hydrogen up to `xhigh`.

### Changed
- agy calls pass session-only settings `{"permissions":{"deny":["command(*)"]}}`. In headless mode a command that needs approval is auto-denied and **ends the turn with no answer**. Hydrogen reaches for the shell often, even for trivial questions, so its turns aborted. With an explicit deny, the denial goes back to the model and the turn continues. The deny also overrides the user's global agy allow-list, which plan mode otherwise honours.
- The agy read-only preamble now says that the shell is disabled, points to `files.txt`, and tells the model to answer within the turn instead of writing a plan and asking for approval (plan mode injects that template).
- `-Compact` also runs with `--mode plan` and the deny rule (the agy 1.5.7 default mode is Auto).
- Argon quota: at 5% left the script now exits 3 and points to `hydrogen`, instead of falling back to Flash.
- The exit-2 (busy) message suggests `-Thread`.

### Removed
- The Gemini Flash fallback (`-Flash`, `agyFallbackModel`, the `agy-flash` session). Flash shares the Gemini pool with Hydrogen and is weaker, so it no longer adds anything.

## 2026-10-24: frontier collaborators

- Reworked into `codex` (GPT-6 Astra, opinions), `codex-run` (GPT-6.1 Sol, executes tasks) and `agy` (Gemini 4 Argon, opinions).
- Codex runs in the workspace-write sandbox with its workspace at `.claude/collab/work/`; `-Yolo` for `codex-run` only, with a repository-change report.
- Argon quota reserve and stop thresholds, Flash fallback; reports saved to `.claude/collab/reports/`.

## 2026-10-23: first version

- `advisors` skill: read-only Codex and Antigravity advisors for Claude Code.
