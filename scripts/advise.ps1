<#
.SYNOPSIS
  Delegate work to frontier agents - Codex CLI and Antigravity CLI (agy) - from Claude Code,
  keeping one persistent conversation per agent per project.

.DESCRIPTION
  codex     : independent senior engineer (gpt-6-astra). Reads the whole repo, runs commands,
              writes ONLY under <root>/.claude/collab/work (enforced by the workspace-write sandbox).
  codex-run : same sandbox, gpt-6.1-sol, for executing delegated tasks.
  hydrogen  : agy CLI with Gemini 4 Hydrogen (xhigh). Read-only (--mode plan). Shared Gemini quota pool.
  agy       : agy CLI with Gemini 4 Argon (high), the frontier Gemini. Read-only. Separate, small Argon quota.
              Alias: argon.

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
# Session-only settings (never saved). An explicit deny rule beats the user's global allow-list, and the
# denial is returned to the model as a tool error. Without it, headless mode auto-denies any command that is
# not allow-listed and ENDS THE TURN, losing the answer (Hydrogen reaches for the shell often).
$AgyDenyCommands = '{"permissions":{"deny":["command(*)"]}}'

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
    $r = Invoke-Proc $AgyExe @('--conversation', $entry.id, '--model', $entry.model, '--mode', 'plan', '--settings', $AgyDenyCommands, '--output-format', 'json', '--print-timeout', "$($TimeoutMinutes)m", '-p', '/compact') $null $root $timeoutSec
    Write-Host "[collab] $key compact | session=$($entry.id) | exit=$($r.Code) | $([int]$sw.Elapsed.TotalSeconds)s"
    return
}

# --- prompt ------------------------------------------------------------------
if ($PromptFile) { $Prompt = Get-Content $PromptFile -Raw }
if (-not $Prompt) { throw 'Provide -Prompt or -PromptFile' }
$isNew = -not ($entry -and $entry.id)

if ($Agent -like 'codex*') {
    $role = if ($Agent -eq 'codex-run') { 'a research engineer executing a delegated task: carry it out end to end (run the code, check the results) and report what you did and found' }
            else { 'an independent senior research engineer and reviewer: give your own analysis, critique and recommendations, running checks when they help' }
    $py =if ($PythonExe) { "Python: $PythonExe (call it by full path; it is not on PATH inside your sandbox)." } else { '' }
    $net = if ($CodexNetwork -or $Yolo) { 'Network access is available.' } else { 'No network access.' }
    if ($Yolo) { $py = "Python: $PythonExe. You are running WITHOUT a sandbox for this task, so the write boundary below is a rule you must keep, not a technical limit." }
    $preamble = @"
[COLLABORATION CONTEXT] You are $role, working alongside the main agent (Claude Code) on the project at:
  $root
You can read the entire repository and run commands (tests, scripts, experiments). $py $net
WRITE ONLY under $work (your workspace: scratch scripts, outputs, notes). Never modify, create or delete files anywhere else in the repository: the main agent owns the code. To propose a code change, write a unified diff to $work\patches\<name>.patch and describe it.
Do not run git commands that change state. Do not read or print secrets (.env, keys, tokens).
Think independently: question the framing of the request, propose alternatives the main agent may not have considered, and back claims with evidence (file:line, command output, numbers). End with: conclusions, evidence, recommendations, open doubts. Be concise.

"@
} else {
    # agy has no directory-listing or search tool once commands are denied: hand it the file list
    $filesTxt = Join-Path $collab 'files.txt'
    $isGit = [bool](git -C $root rev-parse --show-toplevel 2>$null)
    $list = if ($isGit) { git -C $root ls-files --cached --others --exclude-standard 2>$null | Where-Object { $_ -notlike '.claude/collab/*' } }
            else { Get-ChildItem $root -Recurse -File -Name -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '(^|\\)(\.git|node_modules|__pycache__|\.venv|venv)(\\|$)|^\.claude\\collab\\' } }
    $list = @($list)
    $cap = 20000
    $hdr = "# files under $root ($($list.Count) total$(if ($list.Count -gt $cap) { ", first $cap shown" }); paths relative to the root)"
    @($hdr) + @($list | Select-Object -First $cap) | Set-Content $filesTxt -Encoding utf8
    $preamble = @"
[COLLABORATION CONTEXT] You are an independent research scientist advising the main agent (Claude Code) on the project at:
  $root
You are in read-only mode. Read any file you need with read_file. You have no directory-listing or search tool, so the full list of project files is in $filesTxt (refreshed for this turn): read it first when you need to find files. Shell commands are disabled for you (they fail with a permission error), and you must not create, edit or delete files. Do not ask for approval or write a plan for later: answer now, within this turn.
Think independently: question the framing of the request, look for flaws, hidden assumptions and better alternatives the main agent may have missed, and back claims with evidence (file:line, reasoning, references). End with: conclusions, evidence, recommendations, open doubts. Be concise.

"@
}
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
    $common = @('-m', $Model, '-c', "model_reasoning_effort=$Effort") + $sandbox + @('--skip-git-repo-check', '--json')
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
function Invoke-Agy {
    $argv = @('--model', $Model, '--mode', 'plan', '--settings', $AgyDenyCommands, '--output-format', 'json', '--print-timeout', "$($TimeoutMinutes)m")
    if (-not $isNew) { $argv += @('--conversation', $entry.id) }
    $argv += @('-p', $full)
    $r = Invoke-Proc $AgyExe $argv $null $root ($timeoutSec + 60)
    if ($r.TimedOut) { return [pscustomobject]@{ Id = $entry.id; Text = $null; Error = "timed out after $TimeoutMinutes min (process tree killed)"; Denied = @() } }
    try { $j = $r.Out | ConvertFrom-Json } catch { return [pscustomobject]@{ Id = $entry.id; Text = $null; Error = "unparseable agy output: $($r.Out) $($r.Err)".Trim(); Denied = @() } }
    $denied = @($j.denied_actions | Where-Object { $_ } | ForEach-Object { $_.action })
    $e = $null
    if ($j.status -ne 'SUCCESS') { $e = "status=$($j.status) $($r.Err)".Trim() }
    elseif (-not $j.response) { $e = $(if ($denied) { "turn aborted: it attempted a denied action ($($denied -join ', ')); rephrase so it only reads and reasons" } else { "empty response $($r.Err)".Trim() }) }
    [pscustomobject]@{ Id = $j.conversation_id; Text = $j.response; Error = $e; Denied = $denied }
}

# without a sandbox, detect repository changes outside .claude/collab made during the call
function Get-RepoState {
    $s = @{}
    foreach ($l in (git -C $root status --porcelain -uall 2>$null)) {
        $f = $l.Substring(3).Trim('"')
        if ($f -like '.claude/collab/*') { continue }
        $p = Join-Path $root $f
        $s[$f] = if (Test-Path $p -PathType Leaf) { (Get-FileHash $p -Algorithm SHA1).Hash } else { 'deleted' }
    }
    $s
}
$before = if ($Yolo) { Get-RepoState } else { $null }

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
if ($Yolo) {
    $after = Get-RepoState
    $changed = @($after.Keys + $before.Keys | Sort-Object -Unique | Where-Object { $before[$_] -ne $after[$_] })
    if ($changed) { Write-Host "[collab] WARNING (yolo): repository files changed during the call, outside .claude/collab (may include your own concurrent edits): $($changed -join ', ')" }
    else { Write-Host '[collab] yolo: no repository changes outside .claude/collab' }
}
if ($res.Error) { Write-Host "[collab] ERROR: $($res.Error)"; if ($res.Error -match 'timed out') { exit 124 }; exit 1 }

$rp = Join-Path $reports ("{0:yyyyMMdd-HHmmss}-{1}.md" -f (Get-Date), $key)
@("# $key report", '', $header, $(if ($note) { "NOTE: $note" }), '', '## Request', '', $Prompt.Trim(), '', '## Answer', '', $res.Text) | Set-Content $rp -Encoding utf8
Write-Host "[collab] saved: $rp"
$res.Text

} finally { Remove-Item $lock -ErrorAction SilentlyContinue }
