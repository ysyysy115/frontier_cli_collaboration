# Changelog

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
