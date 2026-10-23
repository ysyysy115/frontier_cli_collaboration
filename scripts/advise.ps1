<#
.SYNOPSIS
  Ask a read-only advisor (Codex gpt-6-astra or Antigravity gemini-4-argon) and keep a persistent
  per-project conversation with it.

.DESCRIPTION
  Session ids are stored in <project root>/.claude/advisors.json, keyed by advisor. The first call
  for a project creates a conversation; later calls resume it (never --last / --continue).
  Advisors are read-only: codex via sandbox_mode=read-only, agy via --mode plan, plus a prompt preamble.

.EXAMPLE
  advise.ps1 -Advisor codex -PromptFile q.md
  advise.ps1 -Advisor agy -PromptFile q.md -Effort medium
  advise.ps1 -Advisor codex -Status
  advise.ps1 -Advisor agy -Reset            # forget the session; next call starts a new conversation
#>
param(
    [Parameter(Mandatory)][ValidateSet('codex', 'agy')][string]$Advisor,
    [string]$PromptFile,
    [string]$Prompt,
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')][string]$Effort,
    [string]$Model,
    [switch]$Reset,
    [switch]$Status,
    [int]$Retries = 3
)

$ErrorActionPreference = 'Stop'
$AgyExe = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'

# Configuration, highest priority first: command-line parameter > environment variable > config.json > built-in default.
#   ADVISOR_CODEX_MODEL   codex model id                  (see: codex debug models)
#   ADVISOR_AGY_MODEL     agy model id WITHOUT effort     (see: agy models; "gemini-4-argon" -> gemini-4-argon-high)
#   ADVISOR_EFFORT        low|medium|high|xhigh|max
# config.json (next to SKILL.md): { "codexModel": "...", "agyModel": "...", "effort": "high" }
$cfgFile = Join-Path $PSScriptRoot '..\config.json'
$cfg = @{}
if (Test-Path $cfgFile) { try { $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json -AsHashtable } catch { Write-Warning "config.json unreadable, ignoring" } }
function Get-Setting($envName, $cfgKey, $fallback) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if ($v) { return $v }
    if ($cfg[$cfgKey]) { return $cfg[$cfgKey] }
    return $fallback
}
$Defaults = @{
    codex = Get-Setting 'ADVISOR_CODEX_MODEL' 'codexModel' 'gpt-6-astra'
    agy   = Get-Setting 'ADVISOR_AGY_MODEL' 'agyModel' 'gemini-4-argon'
}
$EffortWasGiven = $PSBoundParameters.ContainsKey('Effort')
if (-not $Effort) { $Effort = Get-Setting 'ADVISOR_EFFORT' 'effort' 'high' }
if ($Effort -notin 'low', 'medium', 'high', 'xhigh', 'max') { throw "Invalid effort '$Effort' (low|medium|high|xhigh|max)" }
$Preamble = @'
[ADVISOR ROLE] You are a read-only advisor to another coding agent. Read files and reason as needed, but do NOT create, modify, delete or move any file, and do not run commands that change state (no installs, no git writes). Give concrete, critical, evidence-based advice: say what you checked, where you disagree, and what you are unsure about. Keep it focused.

'@

# --- project root + registry -------------------------------------------------
$root = (git rev-parse --show-toplevel 2>$null)
if (-not $root) { $root = (Get-Location).Path }
$root = [IO.Path]::GetFullPath($root)
$regDir = Join-Path $root '.claude'
$regPath = Join-Path $regDir 'advisors.json'

function Read-Registry {
    if (Test-Path $regPath) {
        try { return Get-Content $regPath -Raw | ConvertFrom-Json -AsHashtable } catch { Write-Warning "advisors.json unreadable, starting fresh" }
    }
    return @{}
}
function Save-Registry($reg) {
    if (-not (Test-Path $regDir)) { New-Item -ItemType Directory -Path $regDir | Out-Null }
    $reg | ConvertTo-Json -Depth 5 | Set-Content -Path $regPath -Encoding utf8
}

$reg = Read-Registry
$entry = $reg[$Advisor]

if ($Status) {
    if ($entry) { "$Advisor session: $($entry.id)  model=$($entry.model)  turns=$($entry.turns)  last=$($entry.last)" }
    else { "${Advisor}: no session for $root" }
    return
}
if ($Reset) {
    $reg.Remove($Advisor)
    Save-Registry $reg
    "$Advisor session cleared for $root"
    return
}

# --- prompt ------------------------------------------------------------------
if ($PromptFile) { $Prompt = Get-Content $PromptFile -Raw }
if (-not $Prompt) { throw 'Provide -Prompt or -PromptFile' }
$isNew = -not ($entry -and $entry.id)
$full = $Preamble + $Prompt
if ($full.Length -gt 24000 -and $Advisor -eq 'agy') {
    throw "Prompt is $($full.Length) chars; agy takes it as a command-line argument (~32k limit). Point it at files instead of pasting contents."
}

Set-Location $root

# --- model resolution --------------------------------------------------------
if (-not $Model) {
    $Model = if ($Advisor -eq 'agy') { "$($Defaults.agy)-$(if ($Effort -in 'xhigh','max') { 'high' } else { $Effort })" } else { $Defaults.codex }
}
# a resumed conversation keeps its model unless -Model is given explicitly
if (-not $isNew -and -not $PSBoundParameters.ContainsKey('Model')) { $Model = $entry.model; if ($Advisor -eq 'agy' -and $EffortWasGiven) { $Model = "$($Defaults.agy)-$($Effort -replace 'xhigh|max','high')" } }

function Invoke-Codex {
    $cfg = @('-c', "model_reasoning_effort=$Effort")
    if ($isNew) {
        $argv = @('exec', '-m', $Model) + $cfg + @('--sandbox', 'read-only', '--skip-git-repo-check', '--json', '-')
    } else {
        # resume has no --sandbox flag; enforce read-only through config override
        $argv = @('exec', 'resume', $entry.id, '-m', $Model) + $cfg + @('-c', 'sandbox_mode="read-only"', '--skip-git-repo-check', '--json', '-')
    }
    $lines = $full | & codex @argv 2>&1
    $tid = $null; $text = $null; $err = $null
    foreach ($l in $lines) {
        try { $j = "$l" | ConvertFrom-Json } catch { continue }
        switch ($j.type) {
            'thread.started' { $tid = $j.thread_id }
            'item.completed' { if ($j.item.type -eq 'agent_message') { $text = $j.item.text } }
            'turn.failed'    { $err = $j.error.message }
            'error'          { if (-not $err) { $err = $j.message } }
        }
    }
    [pscustomobject]@{ Id = $(if ($tid) { $tid } else { $entry.id }); Text = $text; Error = $err; Denied = @() }
}

function Invoke-Agy {
    $argv = @('--model', $Model, '--mode', 'plan', '--output-format', 'json')
    if (-not $isNew) { $argv += @('--conversation', $entry.id) }
    $argv += @('-p', $full)
    $errFile = New-TemporaryFile
    $raw = & $AgyExe @argv 2>$errFile.FullName
    $stderr = Get-Content $errFile -Raw; Remove-Item $errFile -Force
    try { $j = ($raw | Out-String) | ConvertFrom-Json } catch {
        return [pscustomobject]@{ Id = $entry.id; Text = $null; Error = "unparseable agy output: $raw $stderr"; Denied = @() }
    }
    $denied = @($j.denied_actions | Where-Object { $_ } | ForEach-Object { $_.action })
    $e = $null
    if ($j.status -ne 'SUCCESS') { $e = "status=$($j.status) $stderr" }
    elseif (-not $j.response -and -not $denied) { $e = "empty response $stderr" }
    [pscustomobject]@{ Id = $j.conversation_id; Text = $j.response; Error = $e; Denied = $denied }
}

# --- run with retry on transient capacity/rate errors ------------------------
$res = $null
for ($i = 1; $i -le $Retries; $i++) {
    $res = if ($Advisor -eq 'codex') { Invoke-Codex } else { Invoke-Agy }
    if (-not $res.Error -or $res.Error -notmatch 'capacity|overloaded|rate|temporar|unavailable|timeout') { break }
    if ($i -lt $Retries) { Write-Host "[advisor] transient error ($($res.Error)); retry $i/$($Retries - 1) in 30s" ; Start-Sleep 30 }
}

# --- persist session ---------------------------------------------------------
# A failed first turn can still have created a thread (codex); only record ids that exist.
if ($res.Id) {
    $turns = if ($isNew) { 0 } else { [int]$entry.turns }
    if (-not $res.Error) { $turns++ }
    # a failed call must not change the stored model (e.g. a typo in -Model would poison later resumes)
    $keepModel = if ($res.Error -and -not $isNew) { $entry.model } else { $Model }
    $reg[$Advisor] = @{ id = $res.Id; model = $keepModel; turns = $turns; last = (Get-Date).ToString('s'); created = $(if ($isNew) { (Get-Date).ToString('s') } else { $entry.created }) }
    Save-Registry $reg
}

Write-Host "[advisor] $Advisor | model=$Model | session=$($res.Id) | $(if ($isNew) { 'NEW conversation (no prior context - include a project briefing)' } else { 'resumed' }) | project=$root"
if ($res.Denied.Count) { Write-Host "[advisor] blocked write attempts: $($res.Denied -join ', ') (read-only enforced)" }
if ($res.Error) { Write-Host "[advisor] ERROR: $($res.Error)"; exit 1 }
$res.Text
