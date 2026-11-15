---
name: advisors
description: Work with frontier agents from OpenAI Codex CLI (gpt-6.1-sol, gpt-6-astra) and Google Antigravity CLI (agy: Gemini 4 Hydrogen and Gemini 4 Argon) as independent collaborators that read and search the whole repo, run code, use the web and give their own analysis, so you and the user do not get stuck in a local optimum. Use at the start of significant tasks (independent approaches before you commit), to delegate investigations or experiments, to red-team a plan or result, when results surprise you, when stuck, before declaring a non-trivial result correct, or when the user says "ask codex", "ask agy/gemini/hydrogen/argon", "second opinion". Keeps one persistent conversation per agent per project.
---

# Frontier collaborators: Codex and agy

You are the main agent. You own the code, decide, and integrate. The advisors are frontier models with their own agent loops: they read and search the repository, run code and use the web themselves, so you do not have to relay context, and the user does not have to be the messenger. Their value is **independent perspective**: they catch what you and the user both missed and break you out of local optima. Use them as strong colleagues, not as a chat box.

| | `codex-run` (`gpt-6.1-sol`, medium) | `hydrogen` (`gemini-4-hydrogen`, xhigh) | `codex` (`gpt-6-astra`, high) | `agy` (`gemini-4-argon`, high) |
|---|---|---|---|---|
| Tier | **Everyday** | **Everyday** | **Frontier** | **Frontier** |
| Role | Research engineer: carries out tasks end to end and gives analysis | Research scientist and engineer: opinions, checks | Senior engineer and reviewer: opinions | Senior research scientist: opinions |
| Can | Read and search the repo, run commands (python, tests), network, web search | Read and search the repo, run Python and commands, web search, fetch pages, subagents | Same as `codex-run` | Same as `hydrogen` |
| Writes | Only `<root>/.claude/collab/work/` (sandbox); patches to `work/patches/*.patch` | Only `work/` (by instruction, with guards and a git check as backstop) | Same as `codex-run` | Same as `hydrogen` |
| Best for | Experiments, reproductions, checks and sweeps, data analysis, code review, drafting patches | Method critique, theory, experiment design, hidden assumptions, reviews of plans and documents, literature | Hard reviews, design alternatives, red-teaming, judging results | Your hardest and most consequential questions: deep theory, final red-team before committing |
| Quota | Codex pool, much cheaper | **Shared Gemini pool: large** | Codex pool (shared with codex-run) | **Argon weekly: small** |

The tiers mirror your own models: the everyday pair (Sol, Hydrogen) is like Opus/Sonnet, the frontier pair (Astra, Argon) like Fable. Default to the everyday pair; spend the frontier pair where the extra depth matters. For a complex or consequential question, run all four at once. `-Agent argon` is an alias for `agy`.

Each agent name is a **separate conversation** with a fixed model and effort: a conversation never switches model or effort. So each CLI has two conversations per project, one per model. None of them writes code well enough to replace you: review their patches.

None of them edits the main code. That is your domain, so there are no concurrent edits. Apply their patches yourself after review.

## When to use them

- **Before committing to an approach on a significant task.** Ask for their own approaches first, before showing yours or listing your options (avoid anchoring). Then compare. Default pair: `codex-run` + `hydrogen`.
- **Delegate** a self-contained experiment, reproduction or check to `codex-run` (or `hydrogen`) and keep working while it runs (background).
- **Red-team** a plan, an analysis, or a result before you build on it or report it: "find the weakest point", "how could this conclusion be wrong?".
- **Surprises and dead ends**: a result contradicts expectations, or two genuinely different attempts failed. Ask how to make the owner's direction work, not only what is wrong.
- **Before declaring done** on anything numerical, statistical, or methodological, where an error would be expensive.
- **The user asks.**

Skip for routine edits and lookups you can verify yourself in a minute. **Batch**: collect small doubts and ask them in the next substantial call. A useful rhythm is one round per milestone (review the plan before a run, interpret the result after it), plus a call for a real surprise. Dozens of calls a day is too many.

**Major decisions and reviews** (a revision plan, a protocol, a paper's core method): run all four **in parallel and independently**. Then show each the others' conclusions for critique, and decide yourself.

## How to call

Script: `~/.claude/skills/advisors/scripts/advise.ps1` (PowerShell 7). Run it from inside the project. Write the request to a file first.

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent codex-run -PromptFile <file>   # everyday: task, check, review
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent hydrogen  -PromptFile <file>   # everyday: opinion, check
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent codex     -PromptFile <file>   # frontier opinion / review
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent agy       -PromptFile <file>   # frontier opinion; -Major only for a major decision
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent hydrogen -Thread <name> -PromptFile <file>   # separate conversation, see below
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Status    # sessions, threads, BUSY, last ask, quotas
```

- **Run calls in the background** (`run_in_background: true`); a call takes minutes and sometimes much longer (Astra and Argon at high: often 10 to 30+ min). Keep working; you will be notified. All four agents can run in parallel: each has its own conversation and lock.
- The hard timeout is 45 min by default (`-TimeoutMinutes`); the whole process tree is killed when it is reached.
- **Do not pass `-Model` or change effort.** Each conversation has a fixed model and effort, because switching invalidates the provider's conversation cache. To get a different model, use another agent name.
- The first line is a header: agent, model, NEW/resumed, duration, session, quota and context use. Then the backstop lines (see Rules): `repo check: ...` and, for agy, `guard blocked ...`. Every answer is also saved to `<root>/.claude/collab/reports/<time>-<agent>.md` (the path is printed), so results survive your own context compaction.
- Exit codes: 0 ok · 1 failed · 2 that agent is busy in this project · 3 quota reserved or exhausted (see below) · 124 timeout. **On any failure, say so in one line and continue on your own.** Never block on them.

## Conversations and threads

A conversation is keyed by **project root + agent name** (`<root>/.claude/collab/sessions.json`). Every Claude session in the same project shares it: calling `-Agent hydrogen` resumes the same Hydrogen conversation, whichever Claude session calls it. Its accumulated context is valuable: the advisor remembers the project, earlier results and its own reasoning. Keep using it for the project's main line. `-Thread <name>` (lowercase, digits, `-`; up to 40 chars) opens a separate conversation `hydrogen@<name>` with its own lock, with the same model and rules. `-Reset`, `-Compact` and `-Status` respect `-Thread`.

**Run `-Status` before your first call in a session.** It shows each conversation's turns, last time, `last ask` (the gist of its latest request) and `BUSY` (a call is running, possibly from another Claude session).

Use the **shared conversation** (no `-Thread`) when:
- `-Status` shows no session yet, or its `last ask` is the same workstream you are on (for example, you are continuing earlier work after a restart or compaction).
- You are the only session in the project, and the work is the project's main line.

Use **`-Thread <name>`** when:
- The shared conversation's `last ask` is a different workstream (another Claude session's topic, or an unrelated earlier task). Mixing would confuse the advisor, and your "only what changed" update would be wrong for it.
- The agent shows `BUSY` (or you got exit 2) and you need it now for different work. If it is busy with your *own* workstream, wait instead.
- You want a second **independent** opinion from the same model, not anchored by its earlier turns.

Naming and reuse:
- Name the thread after the **workstream**, not the call: `revision-plan`, `ch3-stats`, `loader-bug`. Reuse the same name for every call in that workstream and across agents, so the set is easy to recognise in `-Status`.
- A new thread is a NEW conversation: it needs the full briefing. Do not open one per call or per milestone; that throws away the advisor's context.
- Write the thread name into your task notes or plan, so that after compaction you, or a later session, continue the same thread.
- When a workstream is finished, `-Reset` its thread so it does not clutter `-Status`.

Start every request with a one-line `Goal: ...`. The script stores the first lines as `last ask`, which is what other sessions see.

## Writing the request

The script injects a top-level preamble into every call: their role, what they can do, the limits, and how to work (form their own view from primary sources, treat the owner's direction as binding, give constructive alternatives as well as critique). You do not need to repeat it. They see the repo but not your conversation.

- **The briefing** (`<root>/.claude/collab/briefing.md`, read by every NEW conversation) holds pointers, not your summary of the project: the owner's direction and hard constraints **in the owner's words**, where the project status lives (`STATUS.md`, the research log), the key code and result files, conventions. Keep it current: update it whenever `STATUS.md` or the direction changes. An outdated or slanted briefing steers every advisor that reads it.
- **New conversation** (header says NEW): tell them to read the briefing and the files it points to.
- **Resumed**: send what changed since their last turn (your edits, new results, decisions) and which files to re-read. Their own context carries the rest.
- **Separate facts from interpretation.** Give facts with their source (file, line, command) so they can check them; mark your interpretation as yours. Check the numbers you send: a wrong fact wastes the whole round.
- **Do not anchor.** For "what should we do next", ask for their own proposals before listing your options, or leave your options out.
- **Ask for both kinds of help**: what is wrong, and how to make the owner's direction succeed. A request that only asks for flaws gets a conservative answer.
- State the goal, what you want back (an approach, a critique, an experiment result, a decision between options), and how much depth.
- For experiments: say what to run, on what data, and where outputs go (`work/`). Ask for the exact commands they ran, so you can reproduce.
- Ask for evidence (file:line, numbers, command output, references) and explicit doubts.

## After the answer

- Check the backstop lines in the header first (see Rules).
- Verify key claims before acting. They are strong but not infallible; patches need your review.
- **Their agreement is input, not a decision.** If the advisors agree on something that narrows the scope, changes the approach or weakens a claim against the owner's direction, take it to the user first.
- Tell the user, in the user's language, what each one said, what you adopted, what you rejected and why. Surface disagreements; do not smooth them over.
- To apply a patch: read it, then make the change yourself (or `git apply` after review).

## Quotas (account-wide: shared by every project and agent)

The script reads agy quota before each `hydrogen`/`agy` call (`agy -p /usage`, free).

- **Shared Gemini pool** (`hydrogen`): large, weekly plus 5-hour windows, shown in the header. At **10% or less weekly left**, `hydrogen` is reserved for major decisions: the script exits 3 unless you pass `-Major`. Use codex instead.
- **Argon** (`agy`) has its own small weekly quota:
  - above 15% left: normal use for frontier questions; everyday opinions go to `hydrogen`.
  - **15% or less: major decisions only.** The script exits 3 unless you pass `-Major`. Use `hydrogen` instead.
  - **5% or less: Argon is off until its reset.** The script exits 3 even with `-Major`. Use `hydrogen`. Hydrogen is not a silent stand-in: it has its own conversation, so brief it properly.
- `-Major` means a genuinely major decision (a protocol, a paper's core method, a change of direction). Do not pass it routinely: it bypasses the reserve that keeps Argon available when it matters.
- **Codex** (`codex` and `codex-run` share one quota): the header shows 5-hour and weekly usage. `codex-run` costs far less. At 90% or more of either window, delegate only what matters.
- Quota errors are not retried. Capacity and overload errors are retried twice, 30 s apart.

## Context

- Codex compacts its own context automatically. The header shows context use.
- `hydrogen` / `agy`: at a task boundary, after many turns or when answers degrade, run `-Agent hydrogen -Compact` (or `-Agent agy -Compact`). The user can also run `/compact` interactively with `agy --conversation <id>`.
- When the topic changes completely, `-Reset` and start fresh from the briefing.

## Rules

- **The preamble is the main control.** It tells every advisor: write only under `work/`, never delete files, no state-changing git, no package installs, no secrets. The agents follow it: in testing they refused such requests on their own.
- **Backstops**, which should normally stay silent:
  - Codex runs in the `workspace-write` sandbox (workspace `work/`).
  - agy runs as a full agent (default mode, no OS sandbox, all commands allowed for the session). Before each call the script writes `PreToolUse` hooks to `work/.agents/hooks.json`: `scripts/guard_write.py` lets agy's file tools write only under `work/`, and `scripts/guard_cmd.py` blocks deletes, state-changing git and package installs. Both fail closed and also cover agy's subagents. Decisions are logged to `.claude/collab/guard-<agent>.log`.
  - For every agent, the script snapshots the working tree as a git tree object before the call and compares after it. `repo check: no changes` is the normal line. A `WARNING: the repository changed` line lists the files and gives a restore command; it can include your own or the user's concurrent edits, so check before restoring. A `guard blocked` line means an advisor tried a forbidden action: tell the user.
- Do not switch agy to plan mode or Auto mode, and keep the hooks. Plan mode does not block writes in agy 1.5.9; Auto forces a terminal sandbox that cannot read the user profile or run Python here.
- `-Yolo` (only for `codex-run`) removes the Codex sandbox for a single call. Use it only when the sandbox blocks a legitimate independent check, such as needing a GPU or data outside the repo. Environment changes (`pip install`, conda), main training runs and core experiments are **your** job: do not delegate them.
- Do not send secrets. Everything they read goes to OpenAI or Google.
- `.claude/collab/` is git-ignored (via its own `.gitignore`).
- Concurrent calls: one call per conversation at a time (lock per agent, per thread, per project). Different agents, threads or projects run in parallel.

## Verified behaviour (codex-cli 0.167.2, agy 1.5.9, Windows 11 24H2, 2026-11-15)

- codex `exec resume` has no `--sandbox` or `-C`: the sandbox is set with `-c sandbox_mode=...` and the workspace is the process working directory (`work/`). The script passes `-c web_search="live"` (with network on), so web search does not depend on the user's `config.toml`.
- The codex Windows sandbox (`elevated`) runs as `CodexSandboxUsers`. It reads the repo but not `%LOCALAPPDATA%` by default, so anaconda needs a read grant: `icacls <anaconda> /grant "CodexSandboxUsers:(OI)(CI)RX" /T`. `unelevated` mode failed to start processes in testing.
- The sandbox blocked writes, deletes and `git commit` outside `work/` for a repository in the user profile. It did **not** block them for a repository under `%TEMP%`, because the temp directory is writable in `workspace-write`: do not test the boundary there.
- Inside the sandbox, HTTPS downloads from the shell (curl, `Invoke-WebRequest`) failed with Schannel errors; the built-in web search worked.
- A user hook that rewrites commands (rtk's `PreToolUse` hook) broke every rewritten command in the sandbox (`rtk: Cannot determine Claude config directory`); setting `HOME` did not help. The script passes `--disable hooks` unless `codexHooks` is true; with it, git and `rg` work and `git commit` is still refused by the sandbox.
- agy models: `gemini-4-argon-{low,medium,high}`, `gemini-4-hydrogen-{low,medium,high,xhigh}` (`agy models`). Effort is the model-name suffix. `/usage` groups: `gemini-weekly`/`gemini-5h` (shared pool) and `gemini-argon-wtu-weekly` (Argon). A Hydrogen call moves only the shared pool.
- agy headless runs start in the saved agent mode (Auto by default). `--mode auto` on the command line is refused in print mode ("rollout flag off") although the session itself runs in Auto. The script passes `agentMode: ""` (default mode) in `--settings`.
- Auto mode runs commands in the Windows terminal sandbox. In testing that sandbox could not read files under the user profile, write its own workspace, start Python from `%LOCALAPPDATA%`, or pass TLS through its proxy; its reviewer also approved commands leaving the sandbox. It is not usable as a boundary here.
- Plan mode (`--mode plan`) did **not** block `write_file` in agy 1.5.9 (a probe file was created).
- Default mode with `permissions.allow: ["command(*)"]` and `enableTerminalSandbox: false`: commands run directly, Python and `rg` work, `Invoke-WebRequest` works, and nothing needs approval, so headless turns do not abort.
- Hooks are loaded from `.agents/hooks.json` under the launch directory (`work/`), also when resuming a conversation created elsewhere. `PreToolUse` with `decision: deny` blocks the call and returns the reason to the model as a tool error; the turn continues. A crashing hook also blocks the call. Hooks apply to subagents' tool calls. Tool arguments: `write_file` has `Path`, `Content`, `Overwrite`; `run_command` has `CommandLine`.
- A resumed conversation keeps the workspace it was created in (older conversations: the repo root), so the preamble gives the workspace as an absolute path.
- Custom agents (`.agents/agents/<name>.md` with a `tools:` list) can remove tools, but in testing the legacy `grep_search`, `find_by_name`, `list_dir` and `read_url_content` were accepted and then not exposed; `excludeDefaultComponents: true` made the list ignored. Not used.
- agy default tools: `read_file, write_file, edit_file, run_command, search_web, manage_task, ask_question, run_workflow, schedule, invoke_subagent, define_subagent, manage_subagents, send_message, swarm`.
- `agy -p "/usage" --output-format json` returns quota buckets without spending quota (run it from PowerShell: Git Bash rewrites `/usage` into a path). Codex rate limits come from `token_count` events in `~/.codex/sessions/**/rollout-*.jsonl`.
