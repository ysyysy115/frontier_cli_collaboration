---
name: advisors
description: Work with frontier agents from OpenAI Codex CLI (gpt-6-astra, gpt-6.1-sol) and Google Antigravity CLI (agy: Gemini 4 Hydrogen and Gemini 4 Argon) as independent collaborators that read the whole repo and give their own analysis, so you and the user do not get stuck in a local optimum. Use at the start of significant tasks (independent approaches before you commit), to delegate investigations or experiments (codex can run code), to red-team a plan or result, when results surprise you, when stuck, before declaring a non-trivial result correct, or when the user says "ask codex", "ask agy/gemini/hydrogen/argon", "second opinion". Keeps one persistent conversation per agent per project.
---

# Frontier collaborators: Codex and agy

You are the main agent. You own the code, decide, and integrate. The advisors are frontier models with their own agent loops: they read the repository themselves, so you do not have to relay context, and the user does not have to be the messenger. Their value is **independent perspective**: they catch what you and the user both missed and break you out of local optima. Use them as strong colleagues, not as a chat box.

| | `codex` (`gpt-6-astra`, high) | `codex-run` (`gpt-6.1-sol`, medium) | `hydrogen` (`gemini-4-hydrogen`, xhigh) | `agy` (`gemini-4-argon`, high) |
|---|---|---|---|---|
| Role | Senior engineer and reviewer: **opinions** (frontier) | Engineer **executing delegated tasks** | Strong research scientist: **opinions** (high-performance, everyday) | Research scientist: **opinions** (frontier) |
| Can | Read the repo, run commands (python, tests), network | Same | Read files (no shell) | Read files (no shell) |
| Writes | Only `<root>/.claude/collab/work/` (sandbox); patches to `work/patches/*.patch` | Same | Nothing (`--mode plan`) | Nothing (`--mode plan`) |
| Best for | Critique, code review, design alternatives, red-teaming, judging results | Experiments, reproductions, checks and sweeps, data analysis, drafting patches | Method critique, theory, experiment design, hidden assumptions, reviews of plans and documents | Your hardest and most consequential questions: deep theory, final red-team before committing |
| Quota | Codex pool (shared with codex-run) | Codex pool, much cheaper | **Shared Gemini pool: large** | **Argon weekly: small** |

**Frontier tier**: `codex` (Astra) and `agy` (Argon). **Main everyday advisors**: `codex` and `hydrogen`. Hydrogen is strong and has a large quota, so it is the default Google-side opinion. Spend Argon where the extra depth matters. `agy -Agent argon` is an alias for `agy`.

Each agent name is a **separate conversation** with a fixed model and effort: a conversation never switches model or effort. Pick by the kind of work: **thinking** goes to `codex`/`hydrogen`/`agy`, **doing** goes to `codex-run`. None of them writes code well enough to replace you: review their patches.

None of them edits the main code. That is your domain, so there are no concurrent edits. Apply their patches yourself after review.

## When to use them

- **Before committing to an approach on a significant task.** Ask for their own approaches first, before showing yours (avoid anchoring). Then compare. Default pair: `codex` + `hydrogen`.
- **Delegate** a self-contained experiment, reproduction or check to `codex-run` and keep working while it runs (background).
- **Red-team** a plan, an analysis, or a result before you build on it or report it: "find the weakest point", "how could this conclusion be wrong?".
- **Surprises and dead ends**: a result contradicts expectations, or two genuinely different attempts failed.
- **Before declaring done** on anything numerical, statistical, or methodological, where an error would be expensive.
- **The user asks.**

Skip for routine edits and lookups you can verify yourself in a minute. Batch small doubts into the next substantial call instead of spending a call on each.

**Major decisions and reviews** (a revision plan, a protocol, a paper's core method): run the opinion agents **in parallel and independently**: `codex` + `hydrogen`, plus `agy` (Argon) when the stakes justify its quota. Add `codex-run` if something needs to be executed or checked. Then show each the others' conclusions for critique, and decide yourself.

## How to call

Script: `~/.claude/skills/advisors/scripts/advise.ps1` (PowerShell 7). Run it from inside the project. Write the request to a file first.

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent codex     -PromptFile <file>   # opinion / review
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent codex-run -PromptFile <file>   # execute a task
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent hydrogen  -PromptFile <file>   # opinion
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent agy       -PromptFile <file>   # frontier opinion; add -Major for a major decision
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent hydrogen -Thread <name> -PromptFile <file>   # separate conversation, see below
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Status    # sessions, threads, BUSY, last ask, quotas
```

- **Run calls in the background** (`run_in_background: true`); a call takes minutes and sometimes much longer (Astra and Argon at high: often 10 to 30+ min). Keep working; you will be notified. All four agents can run in parallel: each has its own conversation and lock.
- The hard timeout is 45 min by default (`-TimeoutMinutes`); the whole process tree is killed when it is reached.
- **Do not pass `-Model` or change effort.** Each conversation has a fixed model and effort, because switching invalidates the provider's conversation cache. To get a different model, use another agent name.
- The first line is a header: agent, model, NEW/resumed, duration, session, quota and context use. Every answer is also saved to `<root>/.claude/collab/reports/<time>-<agent>.md` (the path is printed), so results survive your own context compaction.
- Exit codes: 0 ok · 1 failed · 2 that agent is busy in this project · 3 quota reserved or exhausted (see below) · 124 timeout. **On any failure, say so in one line and continue on your own.** Never block on them.

## Conversations and threads

A conversation is keyed by **project root + agent name** (`<root>/.claude/collab/sessions.json`). Every Claude session in the same project shares it: calling `-Agent hydrogen` resumes the same Hydrogen conversation, whichever Claude session calls it. `-Thread <name>` (lowercase, digits, `-`; up to 40 chars) opens a separate conversation `hydrogen@<name>` with its own lock, with the same model and rules. `-Reset`, `-Compact` and `-Status` respect `-Thread`.

**Run `-Status` before your first call in a session.** It shows each conversation's turns, last time, `last ask` (the gist of its latest request) and `BUSY` (a call is running, possibly from another Claude session).

Use the **shared conversation** (no `-Thread`) when:
- `-Status` shows no session yet, or its `last ask` is the same workstream you are on (for example, you are continuing earlier work after a restart or compaction). Its accumulated context is the point.
- You are the only session in the project, and the work is the project's main line.

Use **`-Thread <name>`** when:
- The shared conversation's `last ask` is a different workstream (another Claude session's topic, or an unrelated earlier task). Mixing would confuse the advisor, and your "only what changed" update would be wrong for it.
- The agent shows `BUSY` (or you got exit 2) and you need it now for different work. If it is busy with your *own* workstream, wait instead.
- You want a second **independent** opinion from the same model, not anchored by its earlier turns (for example a fresh red-team of a plan the shared conversation helped write).

Naming and reuse:
- Name the thread after the **workstream**, not the call: `revision-plan`, `ch3-stats`, `loader-bug`. Reuse the same name for every call in that workstream and across agents (`-Agent codex -Thread revision-plan` and `-Agent hydrogen -Thread revision-plan`), so the set is easy to recognise in `-Status`.
- A new thread is a NEW conversation: it needs the full briefing. Do not open one per call; that throws away the advisor's context and costs a briefing each time.
- Write the thread name into your task notes or plan (for example next to the `/loop` prompt), so that after compaction you, or a later session, continue the same thread.
- When a workstream is finished, `-Reset` its thread so it does not clutter `-Status`.

Start every request with a one-line `Goal: ...`. The script stores the first lines as `last ask`, which is what other sessions see.

## Writing the request

They see the repo but not your conversation.

- **New conversation** (header says NEW): start with a briefing. What the project is, the current goal, key files and docs to read (paths, not pasted code), conventions and constraints. Keep a reusable briefing at `<root>/.claude/collab/briefing.md` and tell them to read it.
- **Resumed**: send only what changed since their last turn (your edits, new results, decisions). Tell them which files to re-read.
- State the goal, what you know and believe, what you want back (an approach, a critique, an experiment result, a decision between options), and how much depth.
- For codex experiments: say what to run, on what data, and where outputs go (`work/`). It runs python by full path (given in its preamble). For results, ask for the exact commands it ran so you can reproduce.
- For `hydrogen` and `agy`: they only read and reason. They have `read_file` but **no directory listing, no grep and no shell**. The script refreshes the project file list at `.claude/collab/files.txt` before every call and points them to it. Still **name the key files and sections** in the request: they cannot search file contents, so they find things only by opening files.
- Ask for evidence (file:line, numbers, command output) and explicit doubts.

## After the answer

- Verify key claims before acting. They are strong but not infallible; codex patches need your review.
- Tell the user what each one said, what you adopted, what you rejected and why. Surface disagreements; do not smooth them over.
- To apply a codex patch: read it, then make the change yourself (or `git apply` after review).

## Quotas (account-wide: shared by every project and agent)

The script reads agy quota before each `hydrogen`/`agy` call (`agy -p /usage`, free).

- **Shared Gemini pool** (`hydrogen`; also Flash): large, weekly plus 5-hour windows, shown in the header. At **10% or less weekly left**, `hydrogen` is reserved for major decisions: the script exits 3 unless you pass `-Major`. Use codex instead.
- **Argon** (`agy`) has its own small weekly quota:
  - above 15% left: normal use, but still prefer `hydrogen` for everyday opinions.
  - **15% or less: major decisions only.** The script exits 3 unless you pass `-Major`. Use `hydrogen` instead.
  - **5% or less: Argon is off until its reset.** The script exits 3 even with `-Major`. Use `hydrogen`. Hydrogen is not a silent stand-in: it has its own conversation, so brief it properly.
- **Codex** (`codex` and `codex-run` share one quota): the header shows 5-hour and weekly usage. Prefer `codex-run` for execution work, since it costs far less. At 90% or more of either window, delegate only what matters.
- Quota errors are not retried. Capacity and overload errors are retried twice, 30 s apart.

## Context

- Codex compacts its own context automatically. The header shows context use.
- `hydrogen` / `agy`: at a task boundary, after many turns or when answers degrade, run `-Agent hydrogen -Compact` (or `-Agent agy -Compact`). The user can also run `/compact` interactively with `agy --conversation <id>`.
- When the topic changes completely, `-Reset` and start fresh from the briefing.

## Rules

- Never pass `--dangerously-skip-permissions` to agy: its file tool then writes outside the workspace (verified).
- agy calls always run with `--mode plan` (blocks file writes) and session-only settings `{"permissions":{"deny":["command(*)"]}}` (blocks every shell command, including ones on the user's global allow-list). Do not remove either.
- **Codex runs sandboxed by default**, which is what keeps it out of the main code. `-Yolo` (only for `codex-run`) removes the sandbox for a single call. Use it only when the sandbox blocks a legitimate independent check, such as needing a GPU or data outside the repo. Environment changes (`pip install`, conda), main training runs and core experiments are **your** job: do not delegate them. With `-Yolo` the write boundary is only a prompt rule. The script compares repository state before and after the call and warns about changed files outside `.claude/collab`; check that warning.
- Do not send secrets. Everything they read goes to OpenAI or Google.
- `.claude/collab/` is git-ignored (via its own `.gitignore`).
- Concurrent calls: one call per conversation at a time (lock per agent, per thread, per project). Different agents, threads or projects run in parallel.

## Verified behaviour (codex-cli 0.164.0, agy 1.5.8, Windows 11, 2026-11-13)

- codex `exec resume` has no `--sandbox` or `-C`: the sandbox is set with `-c sandbox_mode=...` and the workspace is the process working directory (`work/`).
- The codex Windows sandbox (`elevated`) runs as `CodexSandboxUsers`. It reads the repo but not `%LOCALAPPDATA%` by default, so anaconda needs a read grant: `icacls <anaconda> /grant "CodexSandboxUsers:(OI)(CI)RX" /T`. `unelevated` mode failed to start processes in testing.
- agy models: `gemini-4-argon-{low,medium,high}`, `gemini-4-hydrogen-{low,medium,high,xhigh}`, `gemini-3.8-flash-*` (`agy models`). Effort is the model-name suffix. `/usage` groups: `gemini-weekly`/`gemini-5h` (shared pool: Hydrogen, Flash, Pro) and `gemini-argon-wtu-weekly` (Argon). A Hydrogen call moves only the shared pool.
- agy headless: a command that needs approval is auto-denied and **ends the whole turn with no answer**. Commands on the user's global allow-list (`~/.gemini/config/config.json`, e.g. `git status` or a project's verification script) run even in plan mode. An explicit `deny: ["command(*)"]` via `--settings` overrides that allow-list, and the denial goes back to the model as a tool error, so the turn continues. A deny rule always beats a more specific allow rule. Plain `deny: ["command"]` still ends the turn.
- Hydrogen often reaches for the shell, even for trivial questions such as "what model are you". Without the deny rule this aborted its turns.
- agy tools in plan mode: `read_file, write_file, edit_file, run_command, manage_task, search_web`, plus subagent, swarm and schedule tools. There is no list or grep tool. File writes are refused in plan mode and the turn continues. Plan mode injects a "write a plan and ask for approval" template; the preamble tells it to answer within the turn instead.
- Since agy 1.5.7 the default agent mode is Auto; the script always passes `--mode plan`.
- `agy -p "/usage" --output-format json` returns quota buckets without spending quota (run it from PowerShell: Git Bash rewrites `/usage` into a path). Codex rate limits come from `token_count` events in `~/.codex/sessions/**/rollout-*.jsonl`.
