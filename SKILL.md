---
name: advisors
description: Work with two frontier agents, OpenAI Codex CLI and Google Antigravity CLI (agy, Gemini Argon), as independent collaborators that read the whole repo and give their own analysis, so you and the user do not get stuck in a local optimum. Use at the start of significant tasks (independent approaches before you commit), to delegate investigations or experiments (codex can run code), to red-team a plan or result, when results surprise you, when stuck, before declaring a non-trivial result correct, or when the user says "ask codex", "ask agy/gemini", "second opinion". Keeps one persistent conversation per agent per project.
---

# Frontier collaborators: Codex and agy

You are the main agent. You own the code, decide, and integrate. Codex and agy are frontier models with their own agent loops: they explore the repository themselves, so you do not have to relay context, and the user does not have to be the messenger. Their value is **independent perspective**: they catch what you and the user both missed and break you out of local optima. Use them as strong colleagues, not as a chat box.

| | `codex` (`gpt-6-astra`, high) | `codex-run` (`gpt-6.1-sol`, medium) | `agy` (`gemini-4-argon`, high) |
|---|---|---|---|
| Role | Independent senior engineer and reviewer: **opinions** | Engineer **executing delegated tasks** | Independent research scientist: **opinions** |
| Can | Read the whole repo, run commands (python, tests), network | Same | Read the whole repo, reason |
| Writes | Only `<root>/.claude/collab/work/` (sandbox-enforced); code proposals go to `work/patches/*.patch` | Same | Nothing (`--mode plan`) |
| Best for | Critique, code review, design alternatives, red-teaming, judging results | Running experiments, reproducing results, checks and sweeps, data analysis, drafting patches. Much faster and cheaper than astra, still frontier. | Method critique, theory and derivations, experiment design, hidden assumptions, literature-level knowledge |
| Caveats | Slow, costs more quota | Less deep than astra: for judgment calls, ask `codex` or `agy` | Flaky at times; smallest quota (Argon weekly); read-only on purpose |

`codex` and `codex-run` are **separate conversations** with fixed models: a conversation never switches model or effort. Pick by the kind of work: **thinking** goes to `codex`/`agy`, **doing** goes to `codex-run`. Neither writes code well enough to replace you: review their patches.

Neither edits the main code. That is your domain, so there are no concurrent edits. Apply their patches yourself after review.

## When to use them

- **Before committing to an approach on a significant task.** Ask each for its own approach first, before showing yours (avoid anchoring). Then compare.
- **Delegate** a self-contained experiment, reproduction or check to `codex-run` and keep working while it runs (background).
- **Red-team** a plan, an analysis, or a result before you build on it or report it: "find the weakest point", "how could this conclusion be wrong?".
- **Surprises and dead ends**: a result contradicts expectations, or two genuinely different attempts failed.
- **Before declaring done** on anything numerical, statistical, or methodological, where an error would be expensive.
- **The user asks.**

Skip for routine edits and lookups you can verify yourself in a minute. Batch small doubts into the next substantial call instead of spending a call on each. For major decisions, get both opinions independently, then show each the other's conclusion for critique, and decide yourself.

## How to call

Script: `~/.claude/skills/advisors/scripts/advise.ps1` (PowerShell 7). Run it from inside the project. Write the request to a file first.

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent codex     -PromptFile <file>   # opinion / review
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent codex-run -PromptFile <file>   # execute a task
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Agent agy       -PromptFile <file>   # opinion; add -Major for a major decision
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Status    # sessions, quotas, context use
```

- **Run calls in the background** (`run_in_background: true`); a high-effort call takes minutes and sometimes much longer. Keep working; you will be notified. To use both agents, start them in parallel.
- The hard timeout is 45 min by default (`-TimeoutMinutes`); the whole process tree is killed when it is reached.
- **Do not pass `-Model` or change effort.** Each conversation has a fixed model and effort (`codex` astra high, `codex-run` sol medium, `agy` Argon high), because switching invalidates the provider's conversation cache. To get a different model, use the other agent name.
- The first line is a header: agent, model, NEW/resumed, duration, session, quota and context use. Every answer is also saved to `<root>/.claude/collab/reports/<time>-<agent>.md` (the path is printed), so results survive your own context compaction.
- Exit codes: 0 ok · 1 failed · 2 that agent is busy in this project · 3 Argon quota reserved (see below) · 124 timeout. **On any failure, say so in one line and continue on your own.** Never block on them.

## Writing the request

They see the repo but not your conversation.

- **New conversation** (header says NEW): start with a briefing. What the project is, the current goal, key files and docs to read (paths, not pasted code), conventions and constraints. Keep a reusable briefing at `<root>/.claude/collab/briefing.md` and tell them to read it.
- **Resumed**: send only what changed since their last turn (your edits, new results, decisions). Tell them which files to re-read.
- State the goal, what you know and believe, what you want back (an approach, a critique, an experiment result, a decision between options), and how much depth.
- For codex experiments: say what to run, on what data, and where outputs go (`work/`). It runs python by full path (given in its preamble). For results, ask for the exact commands it ran so you can reproduce.
- For agy: tell it to read and reason only. Any write or command attempt aborts its turn and the answer is lost (exit 1 with "turn aborted").
- Ask for evidence (file:line, numbers, command output) and explicit doubts.

## After the answer

- Verify key claims before acting. They are strong but not infallible; codex patches need your review.
- Tell the user what each one said, what you adopted, what you rejected and why. Surface disagreements; do not smooth them over.
- To apply a codex patch: read it, then make the change yourself (or `git apply` after review).

## Quotas (account-wide: shared by every project and agent)

- **Argon** (agy) has the smallest weekly quota. The script checks it before each agy call (`agy -p /usage`, free):
  - above 15% left: normal use.
  - **15% or less: major decisions only.** The script exits 3 unless you pass `-Major`. Use codex instead, or `-Flash`.
  - **5% or less: Argon is off until its reset.** The script switches to Gemini 3.8 Flash (high) in a separate conversation and labels it REFERENCE-ONLY. Flash is not a frontier model: treat its output as a hint, never as a deciding opinion, and say so to the user.
- **Codex** (`codex` and `codex-run` share one quota): the header shows 5-hour and weekly usage. Prefer `codex-run` for execution work, since it costs far less. At 90% or more of either window, delegate only what matters.
- Quota errors are not retried. Capacity and overload errors are retried twice, 30 s apart.

## Context

- Codex compacts its own context automatically. The header shows context use.
- agy: at a task boundary, after many turns or when answers degrade, run `-Agent agy -Compact`. The user can also run `/compact` interactively with `agy --conversation <id>`.
- When the topic changes completely, `-Reset` and start fresh from the briefing.

## Rules

- Never pass `--dangerously-skip-permissions` to agy: its file tool then writes outside the workspace (verified).
- **Codex runs sandboxed by default**, which is what keeps it out of the main code. `-Yolo` (only for `codex-run`) removes the sandbox for a single call. Use it only when the sandbox blocks a legitimate independent check, such as needing a GPU or data outside the repo. Environment changes (`pip install`, conda), main training runs and core experiments are **your** job: do not delegate them. With `-Yolo` the write boundary is only a prompt rule. The script compares repository state before and after the call and warns about changed files outside `.claude/collab`; check that warning.
- Do not send secrets. Everything they read goes to OpenAI or Google.
- `.claude/collab/` is git-ignored (via its own `.gitignore`).
- Concurrent calls: one call per agent per project at a time (lock). Different agents or projects run in parallel.

## Verified behaviour (tested with codex-cli 0.164.0, agy 1.4.7, Windows 11)

- codex `exec resume` has no `--sandbox` or `-C`: the sandbox is set with `-c sandbox_mode=...` and the workspace is the process working directory (`work/`).
- The codex Windows sandbox (`elevated`) runs as `CodexSandboxUsers`. It reads the repo but not `%LOCALAPPDATA%` by default, so anaconda needs a read grant: `icacls <anaconda> /grant "CodexSandboxUsers:(OI)(CI)RX" /T`. `unelevated` mode failed to start processes in testing.
- agy headless: plan mode denies writes; any denial ends the turn with no output; commands are denied without allow-rules; `--mode auto` may be unavailable depending on the account.
- `agy -p "/usage" --output-format json` returns quota buckets without spending quota. Codex rate limits come from `token_count` events in `~/.codex/sessions/**/rollout-*.jsonl`.
