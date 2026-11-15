<#
.SYNOPSIS
  Delegate work to frontier agents - Codex CLI and Antigravity CLI (agy) - from Claude Code,
  keeping one persistent conversation per agent per project.

.DESCRIPTION
  codex     : Codex CLI, gpt-6-astra (high), frontier. Reads the whole repo, runs commands, network,
              writes ONLY under <root>/.claude/collab/work (enforced by the workspace-write sandbox).
  codex-run : same sandbox, gpt-6.1-sol (medium), everyday: executes tasks and gives analysis.
  hydrogen  : agy CLI, Gemini 4 Hydrogen (xhigh), everyday. Shared Gemini quota pool.
  agy       : agy CLI, Gemini 4 Argon (high), frontier. Separate, small Argon quota. Alias: argon.

  Both agy agents work as full agents: they read and search the repo, run Python and commands, search the
  web and fetch pages. The top-level preamble injected into every call sets their limits (write only in
  the workspace, never delete, no state-changing git, no installs). Backstops: PreToolUse hooks that block
  writes outside the workspace, deletes, state-changing git and installs; and a git snapshot of the
  working tree before and after every call, whose differences are reported in the header.

  Every answer is saved under <root>/.claude/collab/reports/. Sessions: <root>/.claude/collab/sessions.json.

.EXAMPLE
  advise.ps1 -Agent codex    -PromptFile task.md
  advise.ps1 -Agent hydrogen -PromptFile question.md
  advise.ps1 -Agent agy      -PromptFile question.md -Major
  advise.ps1 -Status
  advise.ps1 -Agent hydrogen -Compact
  advise.ps1 -Agent codex -Reset
#>
param(
    [ValidateSet('codex', 'codex-run', 'hydrogen', 'agy', 'argon')][string]$Agent,
    [string]$PromptFile,
    [string]$Prompt,
    [switch]$Major,          # agy/hydrogen: allowed to spend the quota reserve (major decision)
    [switch]$Yolo,           # codex-run only: no sandbox, for checks the sandbox blocks (GPU, data outside the repo)
    [switch]$Status,
    [switch]$Reset,
    [switch]$Compact,
    [int]$TimeoutMinutes,
    [string]$Model,
    [int]$Retries = 2,
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,39}$')][string]$Thread   # separate conversation for a distinct workstream
)

$ErrorActionPreference = 'Stop'
$AgyExe = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
# Session-only settings (never saved). Default agent mode (not Auto): Auto forces the terminal sandbox, which on
# Windows cannot read projects under the user profile, write its own workspace, start Python from
# %LOCALAPPDATA% or pass TLS through its proxy. Plan mode is not used either: in agy 1.5.9 it does not block
# file writes, and it adds a plan-for-approval template. Commands are allowed (a headless run auto-denies
# anything that needs approval and can end the turn); the hooks written to <work>/.agents/hooks.json are the
# hard backstop for high-risk actions.
$AgySettings = '{"agentMode":"","enableTerminalSandbox":false,"allowNonWorkspaceAccess":true,"permissions":{"allow":["command(*)"]}}'

# --- configuration: env var > config.json > default --------------------------
$cfgFile = Join-Path $PSScriptRoot '..\config.json'
$cfg = @{}
if (Test-Path $cfgFile) { try { $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json -AsHashtable } catch { Write-Warning 'config.json unreadable, ignoring' } }
function Get-Setting($envName, $key, $fallback) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if ($v) { return $v }
    if ($null -ne $cfg[$key] -and "$($cfg[$key])" -ne '') { return $cfg[$key] }
    return $fallback
}
$CodexModel   = Get-Setting 'COLLAB_CODEX_MODEL' 'codexModel' 'gpt-6-astra'          # codex: opinions, review
$CodexRunModel  = Get-Setting 'COLLAB_CODEX_RUN_MODEL' 'codexRunModel' 'gpt-6.1-sol'  # codex-run: executing tasks
$CodexRunEffort = Get-Setting 'COLLAB_CODEX_RUN_EFFORT' 'codexRunEffort' 'medium'
$AgyModel     = Get-Setting 'COLLAB_AGY_MODEL' 'agyModel' 'gemini-4-argon'      # without effort suffix
$HydrogenModel  = Get-Setting 'COLLAB_HYDROGEN_MODEL' 'hydrogenModel' 'gemini-4-hydrogen'
$HydrogenEffort = Get-Setting 'COLLAB_HYDROGEN_EFFORT' 'hydrogenEffort' 'xhigh'
$Effort       = Get-Setting 'COLLAB_EFFORT' 'effort' 'high'
$ArgonReserve = [double](Get-Setting 'COLLAB_ARGON_RESERVE' 'argonReserve' 0.15)  # below: major decisions only
$ArgonStop    = [double](Get-Setting 'COLLAB_ARGON_STOP' 'argonStop' 0.05)        # below: Argon off (use hydrogen)
$GeminiReserve = [double](Get-Setting 'COLLAB_GEMINI_RESERVE' 'geminiReserve' 0.10) # shared Gemini pool: below, major only
# highest effort tier each agy model offers (agy models): Argon low..high, Hydrogen low..xhigh
function Limit-Effort($e, $max) { $order = 'low', 'medium', 'high', 'xhigh'; $i = [array]::IndexOf($order, ($e -replace 'max', 'xhigh')); if ($i -lt 0) { $i = 2 }; $order[[math]::Min($i, [array]::IndexOf($order, $max))] }
$CodexNetwork = "$(Get-Setting 'COLLAB_CODEX_NETWORK' 'codexNetwork' 'true')" -eq 'true'
# Codex hooks off for advisor calls by default: a hook that rewrites commands (for example rtk's) makes them run a
# wrapper inside the Windows sandbox, where it cannot read the user's config and every git/rg command fails.
$CodexHooks   = "$(Get-Setting 'COLLAB_CODEX_HOOKS' 'codexHooks' 'false')" -eq 'true'
$PythonExe    = Get-Setting 'COLLAB_PYTHON' 'python' ((Get-Command python -ErrorAction SilentlyContinue).Source)
if (-not $TimeoutMinutes) { $TimeoutMinutes = [int](Get-Setting 'COLLAB_TIMEOUT_MINUTES' 'timeoutMinutes' 45) }

# --- project paths -----------------------------------------------------------
$root = (git rev-parse --show-toplevel 2>$null)
if (-not $root) { $root = (Get-Location).Path }
$root = [IO.Path]::GetFullPath($root)
$collab  = Join-Path $root '.claude\collab'
$work    = Join-Path $collab 'work'
$reports = Join-Path $collab 'reports'
$regPath = Join-Path $collab 'sessions.json'
foreach ($d in $collab, $work, $reports) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$gi = Join-Path $collab '.gitignore'
if (-not (Test-Path $gi)) { "*" | Set-Content $gi -Encoding utf8 }   # keep collab artifacts out of the repo

$isGit = [bool](git -C $root rev-parse --show-toplevel 2>$null)

# --- repository snapshot (backstop): the whole working tree as a git tree object ----------------------
# Built in a temporary copy of the index, so the user's index, branches and stash are untouched. Untracked
# files larger than 20 MB are not hashed into objects; they are compared by size and time instead.
function Get-Snapshot {
    if (-not $isGit) { return $null }
    $idx = [IO.Path]::GetTempFileName(); $spec = [IO.Path]::GetTempFileName()
    try {
        $gi = (git -C $root rev-parse --git-path index).Trim()
        if (-not [IO.Path]::IsPathRooted($gi)) { $gi = Join-Path $root $gi }
        if (Test-Path $gi) { Copy-Item $gi $idx -Force } else { Remove-Item $idx }
        $big = @{}
        $lines = @('.')
        foreach ($f in (git -C $root ls-files -o --exclude-standard -z 2>$null) -split "`0") {
            if (-not $f) { continue }
            $fi = Get-Item -LiteralPath (Join-Path $root $f) -ErrorAction SilentlyContinue
            if ($fi -and $fi.Length -gt 20MB) { $big[$f] = "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"; $lines += ":(exclude,literal)$f" }
        }
        $lines | Set-Content $spec -Encoding utf8
        $env:GIT_INDEX_FILE = $idx
        git -C $root add -A --pathspec-from-file="$spec" 2>$null | Out-Null
        $tree = (git -C $root write-tree 2>$null)
        $refs = (git -C $root for-each-ref --format='%(refname) %(objectname)' 2>$null) -join "`n"
        $head = (git -C $root rev-parse HEAD 2>$null)
        return @{ tree = "$tree".Trim(); refs = $refs; head = "$head".Trim(); big = $big }
    } catch { return $null }
    finally { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue; Remove-Item $idx, $spec -ErrorAction SilentlyContinue }
}
function Compare-Snapshot($a, $b) {
    $msgs = @()
    if (-not $a -or -not $b -or -not $a.tree -or -not $b.tree) { return @('repo check: snapshot unavailable') }
    $diff = @(git -C $root diff-tree -r --name-status $a.tree $b.tree 2>$null | Where-Object { $_ })
    foreach ($k in (@($a.big.Keys) + @($b.big.Keys) | Sort-Object -Unique)) { if ($a.big[$k] -ne $b.big[$k]) { $diff += "M?`t$k (large untracked file)" } }
    if ($diff) {
        $msgs += "WARNING: the repository changed during the call (may include your own concurrent edits): $(($diff | ForEach-Object { $_ -replace "`t", ' ' }) -join '; ')"
        $msgs += "  pre-call snapshot: tree $($a.tree). Restore a file: git restore --source=$($a.tree) --worktree -- <path>. Remove added files by hand."
    }
    if ($a.refs -ne $b.refs -or $a.head -ne $b.head) { $msgs += "WARNING: git refs or HEAD changed during the call (HEAD $($a.head) -> $($b.head)). Check git log and git reflog." }
    if (-not $msgs) { $msgs += 'repo check: no changes outside .claude/collab' }
    $msgs
}

function Read-Registry { if (Test-Path $regPath) { try { return Get-Content $regPath -Raw | ConvertFrom-Json -AsHashtable } catch {} }; return @{} }
function Save-Registry($reg) { $reg | ConvertTo-Json -Depth 5 | Set-Content -Path $regPath -Encoding utf8 }

# --- process runner with hard timeout (kills the whole tree) -----------------
function Invoke-Proc([string]$exe, [string[]]$argv, [string]$stdin, [string]$cwd, [int]$timeoutSec) {
    $psi = [Diagnostics.ProcessStartInfo]::new($exe)
    foreach ($a in $argv) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $cwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
    if ($stdin) { $p.StandardInput.Write($stdin) }
    $p.StandardInput.Close()
    $timedOut = -not $p.WaitForExit($timeoutSec * 1000)
    if ($timedOut) { try { $p.Kill($true) } catch {}; $p.WaitForExit(10000) | Out-Null }
    [pscustomobject]@{ Out = $outTask.Result; Err = $errTask.Result; Code = $(if ($timedOut) { 124 } else { $p.ExitCode }); TimedOut = $timedOut }
}

# --- quota -------------------------------------------------------------------
function Get-AgyQuota {
    try {
        $r = Invoke-Proc $AgyExe @('-p', '/usage', '--output-format', 'json') $null $env:TEMP 90
        $j = $r.Out | ConvertFrom-Json
        $q = @{}
        foreach ($g in $j.command.data.groups) { foreach ($b in $g.buckets) { $q[$b.id] = @{ left = [double]$b.remaining_fraction; reset = $b.reset_time } } }
        $argon = $q.Keys | Where-Object { $_ -match 'argon' } | Select-Object -First 1
        return @{ argon = $(if ($argon) { $q[$argon] } else { $null }); gemini = $q['gemini-weekly']; gemini5h = $q['gemini-5h'] }
    } catch { return $null }
}
function Get-CodexRollout($threadId) {
    $dir = Join-Path $env:USERPROFILE '.codex\sessions'
    if ($threadId) { $f = Get-ChildItem $dir -Recurse -Filter "*$threadId.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1 }
    else { $f = Get-ChildItem $dir -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    if (-not $f) { return $null }
    $line = Select-String -Path $f.FullName -Pattern '"rate_limits"' | Select-Object -Last 1
    if (-not $line) { return $null }
    try {
        $p = ($line.Line | ConvertFrom-Json).payload
        $ctx = $null
        if ($p.info.last_token_usage -and $p.info.model_context_window) { $ctx = [math]::Round(100 * $p.info.last_token_usage.input_tokens / $p.info.model_context_window) }
        return @{ h5 = $p.rate_limits.primary.used_percent; week = $p.rate_limits.secondary.used_percent
                  weekReset = [DateTimeOffset]::FromUnixTimeSeconds([long]$p.rate_limits.secondary.resets_at).LocalDateTime.ToString('MM-dd HH:mm'); ctx = $ctx }
    } catch { return $null }
}
function Format-Pct($f) { if ($null -eq $f) { '?' } else { "$([math]::Round(100 * $f))%" } }

# --- status / reset ----------------------------------------------------------
$reg = Read-Registry
if ($Status) {
    "project: $root"
    $base = 'codex', 'codex-run', 'hydrogen', 'agy'
    $threads = @($reg.Keys | Where-Object { $_ -like '*@*' -and ($_ -split '@')[0] -in $base } | Sort-Object)
    foreach ($k in @($base) + $threads) {
        $e = $reg[$k]
        $busy = ''
        $lf = Join-Path $collab "$k.lock"
        if (Test-Path $lf) { $lp = [int](Get-Content $lf -Raw -ErrorAction SilentlyContinue); if ($lp -and (Get-Process -Id $lp -ErrorAction SilentlyContinue)) { $busy = '  BUSY' } }
        if ($e) { "  $k$busy  session $($e.id)  model=$($e.model)  turns=$($e.turns)  last=$($e.last)$(if ($e.lastAsk) { "`n      last ask: $($e.lastAsk)" })" } else { "  ${k}: no session$busy" }
    }
    $aq = Get-AgyQuota
    if ($aq) { "agy quota: Argon weekly left $(Format-Pct $aq.argon.left) (reset $($aq.argon.reset)); shared Gemini pool (Hydrogen, Flash) weekly left $(Format-Pct $aq.gemini.left), 5h left $(Format-Pct $aq.gemini5h.left) (reset $($aq.gemini5h.reset))" } else { 'agy quota: unavailable' }
    $cq = Get-CodexRollout $reg['codex'].id
    if ($cq) { "codex quota: 5h used $($cq.h5)%, weekly used $($cq.week)% (reset $($cq.weekReset)); context used $($cq.ctx)%  [as of the last codex call]" } else { 'codex quota: unknown (no recent session)' }
    return
}
if (-not $Agent) { throw 'Specify -Agent codex|codex-run|hydrogen|agy (or -Status)' }
if ($Agent -eq 'argon') { $Agent = 'agy' }   # alias; the session key stays 'agy'
$isGemini = $Agent -in 'agy', 'hydrogen'

# --- choose model / session key ------------------------------------------------
$key = if ($Thread) { "$Agent@$Thread" } else { $Agent }   # one conversation (and lock) per key
$guardLog = Join-Path $collab "guard-$key.log"               # agy guard decisions for this conversation
$note = $null
$admin = $Reset -or $Compact   # bookkeeping calls are never blocked by quota
if ($Agent -eq 'agy') {
    $aq = Get-AgyQuota
    if ($aq -and $aq.argon -and -not $admin) {
        if ($aq.argon.left -le $ArgonStop) {
            Write-Host "[collab] agy | Argon weekly quota exhausted ($(Format-Pct $aq.argon.left) left, resets $($aq.argon.reset)). Argon is off until then: use -Agent hydrogen (or codex)."
            exit 3
        }
        if ($aq.argon.left -le $ArgonReserve -and -not $Major) {
            Write-Host "[collab] agy | Argon weekly quota low ($(Format-Pct $aq.argon.left) left, resets $($aq.argon.reset)). Reserved for major decisions: re-run with -Major, or use -Agent hydrogen."
            exit 3
        }
    }
    if (-not $Model) { $Model = "$AgyModel-$(Limit-Effort $Effort 'high')" }
    $Effort = $Model -replace '^.*-', ''
} elseif ($Agent -eq 'hydrogen') {
    $aq = Get-AgyQuota
    if ($aq -and $aq.gemini -and -not $admin -and $aq.gemini.left -le $GeminiReserve -and -not $Major) {
        Write-Host "[collab] hydrogen | shared Gemini weekly quota low ($(Format-Pct $aq.gemini.left) left, resets $($aq.gemini.reset)). Reserved for major decisions: re-run with -Major, or use codex."
        exit 3
    }
    if (-not $Model) { $Model = "$HydrogenModel-$(Limit-Effort $HydrogenEffort 'xhigh')" }
    $Effort = $Model -replace '^.*-', ''
} elseif ($Agent -eq 'codex-run') {
    # separate conversation from 'codex': never switch model or effort inside one conversation
    if (-not $Model) { $Model = $CodexRunModel }
    $Effort = $CodexRunEffort
} elseif (-not $Model) { $Model = $CodexModel }

if ($Yolo -and $Agent -ne 'codex-run') { throw '-Yolo is only for -Agent codex-run' }

$entry = $reg[$key]
if ($Reset) { $reg.Remove($key); Save-Registry $reg; "$key session cleared for $root"; return }

# --- one call at a time per agent per project ----------------------------------
$lock = Join-Path $collab "$key.lock"
if (Test-Path $lock) {
    $lpid = [int](Get-Content $lock -Raw -ErrorAction SilentlyContinue)
    if ($lpid -and (Get-Process -Id $lpid -ErrorAction SilentlyContinue)) { Write-Host "[collab] $key is busy with another call (pid $lpid) in this project (possibly another Claude session). Wait for it, use another agent, or open a separate conversation with -Thread <name>."; exit 2 }
}
$PID | Set-Content $lock
try {

$timeoutSec = $TimeoutMinutes * 60
$sw = [Diagnostics.Stopwatch]::StartNew()

if ($Compact) {
    if (-not $isGemini) { 'codex compacts automatically; nothing to do.'; return }
    if (-not $entry) { "no $key session to compact"; return }
    $r = Invoke-Proc $AgyExe @('--conversation', $entry.id, '--model', $entry.model, '--settings', $AgySettings, '--output-format', 'json', '--print-timeout', "$($TimeoutMinutes)m", '-p', '/compact') $null $work $timeoutSec
    Write-Host "[collab] $key compact | session=$($entry.id) | exit=$($r.Code) | $([int]$sw.Elapsed.TotalSeconds)s"
    return
}

# --- prompt ------------------------------------------------------------------
if ($PromptFile) { $Prompt = Get-Content $PromptFile -Raw }
if (-not $Prompt) { throw 'Provide -Prompt or -PromptFile' }
$isNew = -not ($entry -and $entry.id)

$py = if ($PythonExe) { "Python: $PythonExe (call it by its full path)." } else { 'Python: not configured; use what is on PATH.' }
if ($Agent -like 'codex*') {
    $role = if ($Agent -eq 'codex-run') { 'a research engineer: carry out what is asked end to end (run the code, check the results), report what you did and found, and give your own analysis' }
            else { 'an independent senior research engineer and reviewer: give your own analysis, critique and recommendations, running checks when they help' }
    $can = "Read the whole repository, search it (rg, read-only git), and run commands, scripts and tests. $py " + $(if ($CodexNetwork -or $Yolo) { 'Use your web search tool for literature, documentation and facts (HTTPS downloads from the shell may fail inside the sandbox).' } else { 'No network access.' }) + ' If a command wrapper (for example rtk) fails inside the sandbox, run the command directly.'
    $enforce = if ($Yolo) { "You are running WITHOUT a sandbox for this task, so the limits below are rules you must keep, not technical limits." }
               else { "Your sandbox lets you write only under $work; writes elsewhere fail." }
    $headless = ''
} else {
    $role = 'an independent senior research scientist and engineer: give your own analysis, critique and recommendations, running checks when they help'
    $can = "Read any file; search the repository with shell commands (rg, Get-ChildItem, read-only git: log, show, diff, blame, grep); run Python, scripts and tests ($py) Search the web with search_web and fetch pages (for example Invoke-WebRequest) for literature, documentation and facts. Use subagents only when the work clearly splits: they spend the same quota."
    $enforce = 'Guards enforce these limits as a backstop. A denied action means it broke a rule: do not retry it another way.'
    $headless = "`n- You run headless: nobody can answer questions or approve plans. Do not ask and do not write a plan for approval. Decide, state your assumptions, and answer within this turn."
}
$preamble = @"
[COLLABORATION CONTEXT] You are $role. You work alongside the main agent (Claude Code), which owns the code and makes the decisions, on the project at:
  $root
Your workspace, for scratch scripts, outputs, notes and patches: $work

What you can do: $can

Limits (set by the project owner; not negotiable):
- Do not change the repository. Create or edit files only under $work, using absolute paths. To propose a code change, write a unified diff to $work\patches\<name>.patch and describe it.
- Never delete files, not even in your workspace (overwrite them instead). Never run state-changing git (commit, checkout, reset, stash, push, pull, merge, ...). Never install or remove packages or environments. If one of these is needed, say so in your answer.
- Do not read or print secrets (.env files, keys, tokens).
- Keep runs proportionate: no long training or heavy GPU jobs unless the request asks for them.$headless
$enforce

How to work:
- Form your own view from primary sources: code, result files, logs and data. The main agent's summary in the request can be incomplete or wrong; check the facts that matter yourself and say when they do not hold.
- The owner's stated direction and constraints (in the request, the project briefing or STATUS.md) are binding. Within them, look for the strongest way to succeed, not only for flaws: give both critique and constructive alternatives.
- Question the framing of the request, propose approaches the main agent may have missed, and back claims with evidence (file:line, command output, numbers, references with URLs). State your doubts explicitly.
- End with: conclusions, evidence, recommendations, open doubts. Be concise.

"@
$full = $preamble + $Prompt

# agy takes the prompt as a command-line argument (~32k limit): hand long prompts over as a file
if ($isGemini -and $full.Length -gt 20000) {
    $pf = Join-Path $collab ("prompt-{0:yyyyMMdd-HHmmss}.md" -f (Get-Date))
    $Prompt | Set-Content $pf -Encoding utf8
    $full = $preamble + "Your task is in this file; read it first and follow it: $pf"
}

# --- invoke ------------------------------------------------------------------
function Invoke-Codex {
    $sandbox = if ($Yolo) { @('--dangerously-bypass-approvals-and-sandbox') }
               else { @('-c', 'sandbox_mode="workspace-write"', '-c', "sandbox_workspace_write.network_access=$($CodexNetwork.ToString().ToLower())") }
    $search = if ($CodexNetwork -or $Yolo) { @('-c', 'web_search="live"') } else { @() }   # explicit, not left to the user's config.toml
    $hooksOff = if ($CodexHooks) { @() } else { @('--disable', 'hooks') }
    $common = @('-m', $Model, '-c', "model_reasoning_effort=$Effort") + $sandbox + $search + $hooksOff + @('--skip-git-repo-check', '--json')
    $argv = if ($isNew) { @('exec') + $common + @('-') } else { @('exec', 'resume', $entry.id) + $common + @('-') }
    $r = Invoke-Proc 'codex' $argv $full $work $timeoutSec
    $tid = $null; $text = $null; $err = $null
    foreach ($l in ($r.Out -split "`n")) {
        if (-not $l.Trim()) { continue }
        try { $j = $l | ConvertFrom-Json } catch { continue }
        switch ($j.type) {
            'thread.started' { $tid = $j.thread_id }
            'item.completed' { if ($j.item.type -eq 'agent_message') { $text = $j.item.text } }
            'turn.failed'    { $err = $j.error.message }
            'error'          { if (-not $err) { $err = $j.message } }
        }
    }
    if ($r.TimedOut) { $err = "timed out after $TimeoutMinutes min (process tree killed)" }
    elseif (-not $text -and -not $err) { $err = "no answer (exit $($r.Code)) $($r.Err.Trim())" }
    [pscustomobject]@{ Id = $(if ($tid) { $tid } else { $entry.id }); Text = $text; Error = $err; Denied = @() }
}
# agy loads hooks from the launch directory's .agents/; they also cover its subagents (verified, agy 1.5.9).
# Written fresh every call so the paths always match this project.
function Write-AgyHooks {
    if (-not $PythonExe) { throw 'agy agents need Python for their guard hooks: set COLLAB_PYTHON or "python" in config.json' }
    $dir = Join-Path $work '.agents'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $envs = "set `"GUARD_WORK=$work`" && set `"GUARD_LOG=$guardLog`" && "
    $hooks = @{ 'advisor-guard' = @{ PreToolUse = @(
        @{ matcher = 'write_file|edit_file'; hooks = @(@{ type = 'command'; timeout = 20; command = $envs + "`"$PythonExe`" `"$PSScriptRoot\guard_write.py`"" }) },
        @{ matcher = 'run_command';          hooks = @(@{ type = 'command'; timeout = 20; command = $envs + "`"$PythonExe`" `"$PSScriptRoot\guard_cmd.py`"" }) }
    ) } }
    $hooks | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir 'hooks.json') -Encoding utf8
}
function Invoke-Agy {
    Write-AgyHooks
    $argv = @('--model', $Model, '--settings', $AgySettings, '--output-format', 'json', '--print-timeout', "$($TimeoutMinutes)m")
    if (-not $isNew) { $argv += @('--conversation', $entry.id) }
    $argv += @('-p', $full)
    $r = Invoke-Proc $AgyExe $argv $null $work ($timeoutSec + 60)
    if ($r.TimedOut) { return [pscustomobject]@{ Id = $entry.id; Text = $null; Error = "timed out after $TimeoutMinutes min (process tree killed)"; Denied = @() } }
    try { $j = $r.Out | ConvertFrom-Json } catch { return [pscustomobject]@{ Id = $entry.id; Text = $null; Error = "unparseable agy output: $($r.Out) $($r.Err)".Trim(); Denied = @() } }
    $denied = @($j.denied_actions | Where-Object { $_ } | ForEach-Object { $_.action })
    $e = $null
    if ($j.status -ne 'SUCCESS') { $e = "status=$($j.status) $($r.Err)".Trim() }
    elseif (-not $j.response) { $e = $(if ($denied) { "turn aborted: it attempted an action that needed approval ($($denied -join ', '))" } else { "empty response $($r.Err)".Trim() }) }
    [pscustomobject]@{ Id = $j.conversation_id; Text = $j.response; Error = $e; Denied = $denied }
}

# backstop for every agent: snapshot the working tree now and compare after the call
$before = Get-Snapshot
$guardStart = if (Test-Path $guardLog) { @(Get-Content $guardLog).Count } else { 0 }

$res = $null
for ($i = 1; $i -le ($Retries + 1); $i++) {
    $res = if ($Agent -like 'codex*') { Invoke-Codex } else { Invoke-Agy }
    if (-not $res.Error) { break }
    if ($res.Error -match 'quota|credits|usage limit|limit reached|billing') { break }            # waiting will not help
    if ($res.Error -notmatch 'capacity|overloaded|rate|temporar|unavailable|503|502') { break }
    if ($i -le $Retries) { Write-Host "[collab] transient error ($($res.Error)); retry $i/$Retries in 30s"; Start-Sleep 30 }
}

# --- persist session (a failed call never changes the stored model) ------------
if ($res.Id) {
    $turns = if ($isNew) { 0 } else { [int]$entry.turns }
    if (-not $res.Error) { $turns++ }
    $keepModel = if ($res.Error -and -not $isNew) { $entry.model } else { $Model }
    $created = if ($isNew) { (Get-Date).ToString('s') } else { $entry.created }
    $reg = Read-Registry
    # one-line gist of the latest request, so other Claude sessions can see what this conversation is about (-Status)
    $ask = (($Prompt -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#+\s*$' } | Select-Object -First 2) -join ' ').Trim()
    if ($ask.Length -gt 160) { $ask = $ask.Substring(0, 160) + '...' }
    $reg[$key] = @{ id = $res.Id; model = $keepModel; turns = $turns; last = (Get-Date).ToString('s'); created = $created; lastAsk = $(if ($res.Error -and -not $isNew) { $entry.lastAsk } else { $ask }) }
    Save-Registry $reg
}

# --- report ------------------------------------------------------------------
$secs = [int]$sw.Elapsed.TotalSeconds
$quota = ''
if ($Agent -like 'codex*') { $cq = Get-CodexRollout $res.Id; if ($cq) { $quota = "codex 5h used $($cq.h5)%, week used $($cq.week)% | context $($cq.ctx)%" } }
elseif ($Agent -eq 'agy' -and $aq -and $aq.argon) { $quota = "Argon week left $(Format-Pct $aq.argon.left) (before this call)" }
elseif ($aq -and $aq.gemini) { $quota = "Gemini pool week left $(Format-Pct $aq.gemini.left), 5h left $(Format-Pct $aq.gemini5h.left) (before this call)" }
$state = if ($isNew) { 'NEW conversation (include a project briefing)' } else { "resumed, turn $($reg[$key].turns)" }
$header = "[collab] $key | model=$Model ($Effort) | $state | ${secs}s | session=$($res.Id) | $quota"
Write-Host $header
if ($note) { Write-Host "[collab] NOTE: $note" }
# backstop results: repository changes during the call, and actions the guards blocked
$checks = @()
if ($isGit) { $checks += Compare-Snapshot $before (Get-Snapshot) } else { $checks += 'repo check: not a git repository, no snapshot' }
if ($isGemini -and (Test-Path $guardLog)) {
    $blocked = @(Get-Content $guardLog | Select-Object -Skip $guardStart | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object { $_.decision -eq 'deny' })
    if ($blocked) { $checks += "guard blocked $($blocked.Count) action(s): $(($blocked | ForEach-Object { if ($_.cmd) { $_.cmd } else { "$($_.tool) $($_.args.Path)" } } | Select-Object -First 5) -join ' | ')" }
}
foreach ($c in $checks) { Write-Host "[collab] $c" }
if ($res.Error) { Write-Host "[collab] ERROR: $($res.Error)"; if ($res.Error -match 'timed out') { exit 124 }; exit 1 }

$rp = Join-Path $reports ("{0:yyyyMMdd-HHmmss}-{1}.md" -f (Get-Date), $key)
@("# $key report", '', $header, $(if ($note) { "NOTE: $note" }), ($checks | ForEach-Object { "[collab] $_" }), '', '## Request', '', $Prompt.Trim(), '', '## Answer', '', $res.Text) | Set-Content $rp -Encoding utf8
Write-Host "[collab] saved: $rp"
$res.Text

} finally { Remove-Item $lock -ErrorAction SilentlyContinue }
