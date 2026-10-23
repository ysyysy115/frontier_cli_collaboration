---
name: advisors
description: Consult two frontier-model advisors, OpenAI Codex and Google Antigravity (agy), as read-only second opinions. Use for hard design or architecture decisions, when stuck after two failed attempts, to challenge a plan or conclusion before committing to it, to review a risky change before merging, or whenever the user asks to "ask codex", "ask agy/gemini", or "get a second opinion". Keeps one persistent conversation per advisor per project.
---

# Advisors: Codex and Antigravity (agy)

Two other frontier models, driven through their CLIs. Models and effort come from `ADVISOR_*` environment variables or `config.json` (see README); the defaults are `gpt-6-astra` and `gemini-4-argon` at `high`. They can **read** the project but **cannot write**.
You (the main agent) stay in charge: you decide, you edit, you own the result.

## Principles

1. **Advisors are optional.** If a call fails, times out, or the model is at capacity, say so in one line and continue on your own. Never block on an advisor, never loop on retries beyond what the script does, and never silently substitute another model (a different model is a different opinion; tell the user if you switch).
2. **Advice is evidence, not instruction.** Check claims against the code. If you disagree, say why. Report disagreements between advisors, or between an advisor and you, to the user rather than papering over them.
3. **Read-only is enforced twice.** Codex runs with `sandbox_mode=read-only`; agy runs with `--mode plan` (write attempts are denied and reported). The script also prefixes every prompt with a read-only role. Never pass `--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`, or `--sandbox workspace-write` to an advisor.
4. **One persistent conversation per advisor per project.** Never start a fresh conversation for each question; the script resumes the stored session by explicit id (never `--last` / `--continue`, which can hit the wrong conversation).
5. **Privacy.** Everything in the prompt, and any file the advisor reads, goes to OpenAI or Google. Do not send secrets, credentials, `.env` contents, or material the user marked sensitive. When unsure whether a project may leave the machine, ask the user once.

## When to consult: rarely, and in batches

Every call is slow (often 1-10+ min at `high`) and uses the user's quota, so consult **sparingly**. Two modes:

1. **Major decision: ask right away.** Only for things that are costly to get wrong or to undo: a core architecture or design choice, a plan for a large or risky change before you start it, a result you are about to declare correct where an error would be expensive (numerical results, concurrency, security, data migrations), or being truly stuck after two genuinely different attempts failed.
2. **Everything else: park it and batch it.** When a smaller question or doubt comes up that you can resolve yourself or work around, do not interrupt the work to ask. Append it to `<root>/.claude/advisor-queue.md` (one bullet: the question, the file/path it concerns, what you currently believe) and keep going. Send the queue as **one combined prompt** at a natural checkpoint: end of a milestone, before a commit/merge, when the queue holds several items, or when the user asks. Clear the queue after the answer is in.

Never ask both advisors by default. Pick the one that fits, and ask the second only for a major decision where independent opinions matter, or when the first answer is unconvincing. Do not consult for routine edits, lookups, or anything you can verify by running a test or reading the code. The user asking you to consult always overrides this.

## How to call

Script: `~/.claude/skills/advisors/scripts/advise.ps1` (PowerShell 7). Run it from inside the project. It finds the project root (git top level, else cwd) and keeps sessions in `<root>/.claude/advisors.json`.

1. Write the question to a file (avoids quoting problems), e.g. in the scratchpad or `<root>/.claude/advisor-q.md`.
2. Run, with a generous Bash timeout (up to 600000 ms) or `run_in_background: true` if it may take longer:

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Advisor codex -PromptFile <file>
pwsh -NoProfile -File "$HOME/.claude/skills/advisors/scripts/advise.ps1" -Advisor agy   -PromptFile <file>
```

To get both opinions, launch the two calls in parallel (two tool calls in one message) so they do not wait on each other.

**Effort is fixed at `high`. Do not pass `-Effort` or `-Model`** unless the user tells you to. Changing effort or model changes the request prefix and forces the provider to reload the conversation cache, which makes the next call slower and costlier. A resumed conversation automatically keeps its original model and effort. Other options: `-Status` shows the stored session, `-Reset` forgets it (next call starts a new conversation).

The first output line is a status header: `[advisor] <name> | model | session | NEW or resumed | project`. Exit code 1 means the call failed (the header explains why); transient capacity/rate errors are retried 3 times, 30 s apart, before giving up.

## Writing a good prompt

The advisor only knows its own conversation, not yours.

- **NEW conversation** (header says NEW, or `-Status` shows none): begin with a short briefing: what the project is, how it is laid out, the conventions that matter, the current goal. Point at paths to read (`README.md`, `docs/...`, `src/...`) rather than pasting code; both advisors run in the project directory and can read it themselves.
- **Resumed conversation**: send only what changed since the last turn: new decisions, edits you made, results of experiments. They do not see your edits unless you say so or tell them to re-read the files.
- Always include: the specific question, what you already tried or believe, the constraints, and what kind of answer you want (critique, alternatives, a decision between A and B, a bug hypothesis list).
- For a challenge, say so: "Find the weakest point in this plan" gets better results than "is this ok?".
- Ask for evidence: file paths, line numbers, a concrete counterexample.
- Keep long prompts under ~20k characters (agy takes the prompt on the command line). Use file paths for bulk.

## After the call

- Summarize the advice for the user in your own words, mark what you verified, what you adopted, and what you rejected and why.
- If the advisor claimed something about the code, spot-check it before acting.
- If the advisor tried to write, the header says `blocked write attempts`; that is expected and harmless, but its advice may then be incomplete: rephrase as "describe the change, do not apply it".
- When the topic changes substantially (new task, new area of the codebase), `-Reset` that advisor and start a clean conversation with a fresh briefing; stale context degrades answers and long conversations get compressed.

## Failure handling

| Symptom | Action |
|---|---|
| `model is at capacity` / rate limit | Script retries 3x. If still failing, tell the user, proceed alone, and try again later at the same settings (keep the question queued). Do not lower the effort. |
| Timeout / no output | Do not wait indefinitely. Run long calls in the background; if it never returns, abandon and say so. |
| `unparseable agy output` | Re-run once. If the same, `-Status`, then `-Reset` and retry. |
| Session id rejected / conversation gone | `-Reset`, then call again with a fresh briefing. |
| CLI not found / not logged in | Tell the user which one (`codex login`, or run `agy` once interactively); proceed alone. |
| Advice contradicts the code | Trust the code; tell the advisor what you found if you resume. |

## Facts verified on this machine (codex-cli 0.164.0, agy 1.4.6)

- `codex exec` has `--sandbox`; `codex exec resume` does not, so read-only on resume is forced with `-c sandbox_mode="read-only"` (tested: writes denied). Model and effort must be passed again on resume.
- The codex thread id comes from the `thread.started` JSONL event. A thread is created even if the first turn fails on capacity, and it remembers the prompt.
- agy `--output-format json` returns `conversation_id`; `--conversation <id>` resumes it. In `-p` mode with `--mode plan`, `write_file` is auto-denied and listed under `denied_actions`.
- agy has no separate effort flag per model here; effort is part of the model id (`gemini-4-argon-low|medium|high`).
