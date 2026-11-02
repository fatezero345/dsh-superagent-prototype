# dsh-superagent.ps1 — Windows control wrapper for the dsh-superagent service.
# Mirrors scripts/dsh-superagent (POSIX) exit codes:
#   0 = runs normally | 1 = stopped/duplicated/unreachable/runtime error
#   2 = runs, non-runtime part reports an error | 3 = runs, waits for setup
# Windows adaptation: Start-Process instead of tmux; Stop-Process instead of SIGINT.
# Usage: .\scripts\dsh-superagent.ps1 <start|stop|restart|status> [-Profile x] [-Url http://127.0.0.1:3082] [-RespectStop]

param(
  [ValidateSet('start','stop','restart','status')][string]$Action = 'status',
  [string]$Profile = $(if ($env:DSH_SUPERAGENT_PROFILE) { $env:DSH_SUPERAGENT_PROFILE } else { 'superagent' }),
  [string]$Url = $(if ($env:DSH_SUPERAGENT_URL) { $env:DSH_SUPERAGENT_URL } else { 'http://127.0.0.1:3082' }),
  [double]$Timeout = 60,
  [double]$StopTimeout = 300,
  [switch]$RespectStop
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Artifacts = Join-Path $RepoRoot '.artifacts'
$Control = Join-Path $Artifacts (Join-Path 'control' (Join-Path 'profiles' $Profile))
New-Item -ItemType Directory -Force -Path $Control | Out-Null
$StopMarker = Join-Path $Control 'manually-stopped'
$PidFile = Join-Path $Control 'service.pid'
$KeepLogs = 20

function Get-State {
  $req = "Url = $Url"; $headers = @{ 'x-orchestrator-request' = '1' }
  try {
    $r = Invoke-RestMethod -Uri ($Url.TrimEnd('/') + '/orchestrator/api/state') -Headers $headers -TimeoutSec 2
    $health = @{}; $errors = @{}; $setup = $null; $feishu = $null
    if ($r.health) { foreach ($k in $r.health.PSObject.Properties) { $v = $k.Value; if ($v -is [psobject]) { $health[$k.Name] = $v.state; if ($v.state -eq 'error') { $errors[$k.Name] = [string]$v.detail } } } }
    if ($r.setup) { $setup = $r.setup.problem }
    if ($r.feishuProblem) { $feishu = $r.feishuProblem }
    return @{ health = $health; errors = $errors; setup = $setup; feishu = $feishu }
  } catch { return $null }
}

function Get-LivePids {
  # Only the DSH service process counts: the `cmd` shim that Start-Process records stays alive as its parent.
  # DSH-X spawns `bin.js <profile> --host … --port …`; this script spawns `--profile <profile>`; accept both.
  $name = [regex]::Escape($Profile)
  $pattern = '(?:--profile\s+' + $name + '|bin\.js\s+"?' + $name + '(?=\s|$))'
  $found = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'DSH.exe' -and $_.CommandLine -match 'bin\.js' -and $_.CommandLine -notmatch 'runner\.js' -and $_.CommandLine -match $pattern } |
    ForEach-Object { [int]$_.ProcessId }
  return @($found | Select-Object -Unique)
}

function RuntimeUp($current) {
  if ($null -eq $current) { return $false }
  return ($current.health['runtime'] -in @('ready','paused'))
}

function PartErrors($current) {
  if ($null -eq $current) { return @{} }
  return $current.errors
}

function Outcome($pids, $current) {
  if ($pids.Count -ne 1 -or -not (RuntimeUp $current)) { return 1 }
  if ($current.setup) { return 3 }
  $pe = PartErrors $current
  return $(if ($pe.Count -gt 0) { 2 } else { 0 })
}

function Show-Status {
  $pids = Get-LivePids
  $current = if ($pids.Count -gt 0) { Get-State } else { $null }
  $out = [ordered]@{
    pids = $pids
    cwd = $RepoRoot
    url = $Url
    manually_stopped = Test-Path $StopMarker
    health = $(if ($current) { $current.health } else { $null })
    errors = $(if ($current) { $current.errors } else { $null })
    setup = $(if ($current) { $current.setup } else { $null })
    feishu = $(if ($current) { $current.feishu } else { $null })
  }
  # Write-Host keeps the status document out of the pipeline so the caller receives only the exit code.
  Write-Host ($out | ConvertTo-Json -Depth 5)
  return (Outcome $pids $current)
}

function Get-GitBinPath {
  # Windows only: the bundle needs POSIX `sh` and `env`, which Git for Windows ships.
  # Override with $env:DSH_SUPERAGENT_GIT_BIN (semicolon-separated directories).
  if ($env:DSH_SUPERAGENT_GIT_BIN) { return $env:DSH_SUPERAGENT_GIT_BIN }
  if ((Get-Command sh -ErrorAction SilentlyContinue) -and (Get-Command env -ErrorAction SilentlyContinue)) { return '' }
  foreach ($root in @("$env:ProgramFiles\Git", "${env:ProgramFiles(x86)}\Git", "$env:LOCALAPPDATA\Programs\Git")) {
    if ($root -and (Test-Path "$root\usr\bin\env.exe")) { return "$root\bin;$root\usr\bin" }
  }
  return ''
}

function Prune-Logs {  $name = 'dsh-superagent-' + $Profile + '-'
  $logs = Get-ChildItem $Artifacts -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like ($name + '*-*.log') } |
    Sort-Object LastWriteTime -Descending
  $logs | Select-Object -Skip $KeepLogs | ForEach-Object { Remove-Item $_.FullName -Force }
}

function Start-Service {
  $pids = Get-LivePids
  if ($pids.Count -gt 1) { throw 'Multiple dsh-superagent processes found; refusing to choose one.' }
  if ($pids.Count -eq 1) {
    Set-Content -Path $PidFile -Value ([string]$pids[0])
    Write-Output "dsh-superagent already running (PID $($pids[0])); no duplicate started."
  } else {
    $dsh = (Get-Command dsh -ErrorAction SilentlyContinue)
    if (-not $dsh) { throw 'dsh must be on PATH.' }
    $existing = Get-State
    if ($null -ne $existing) { throw 'An existing orchestrator answers at this URL; refusing duplicate startup.' }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $log = Join-Path $Artifacts ("dsh-superagent-$Profile-$stamp-$PID.log")
    New-Item -ItemType File -Path $log -Force | Out-Null
    Prune-Logs
    $logErr = $log + '.err.log'
    # Git for Windows supplies the POSIX bits the bundle expects: sh (prepare runs via `sh -c`)
    # and env (setup probes run via `env PATH=... <cli>`). Override with $env:DSH_SUPERAGENT_GIT_BIN.
    $gitPath = Get-GitBinPath
    $oldPath = $env:PATH
    # The poll path spawns the agent CLI directly, so it must be gh.exe; GH_CONFIG_DIR keeps it on the agent account.
    $oldConfig = $env:GH_CONFIG_DIR
    try {
      if ($gitPath) { $env:PATH = "$gitPath;$oldPath" }
      if (-not $env:GH_CONFIG_DIR) { $env:GH_CONFIG_DIR = "$env:USERPROFILE\.config\gh-agent" }
      $p = Start-Process -FilePath $dsh.Source -ArgumentList @('--profile', $Profile, '--no-open') `
        -WorkingDirectory $RepoRoot -WindowStyle Hidden `
        -RedirectStandardOutput $log -RedirectStandardError $logErr -PassThru
    } finally { $env:PATH = $oldPath; $env:GH_CONFIG_DIR = $oldConfig }
    Set-Content -Path $PidFile -Value ([string]$p.Id)
    Write-Output "Log: $log"
  }
  if (Test-Path $StopMarker) { Remove-Item $StopMarker -Force }
  $deadline = (Get-Date).AddSeconds($Timeout)
  while ((Get-Date) -lt $deadline) {
    $current = Get-State
    $pids = Get-LivePids
    if ($pids.Count -ge 1 -and (RuntimeUp $current)) {
      $code = Show-Status
      if ($current.setup) { Write-Output "dsh-superagent is waiting for setup: $($current.setup.detail)" }
      if ($current.feishu) { Write-Output "dsh-superagent runs without Feishu: $($current.feishu.detail)" }
      foreach ($name in $current.errors.Keys) { Write-Output "$name reports an error, which a restart does not fix: $($current.errors[$name])" }
      return $code
    }
    Start-Sleep -Seconds 1
  }
  Show-Status | Out-Null
  throw 'Startup health check timed out; inspect the log. Any running process was left intact.'
}

function Stop-Service([bool]$Intentional) {
  $pids = Get-LivePids
  # Only an instance this script started (its pid is the one recorded) is ours to stop; DSH-X owns the rest.
  $owned = $false
  if (Test-Path $PidFile) {
    try { $recorded = [int](Get-Content $PidFile -Raw); $owned = $pids -contains $recorded } catch { $owned = $false }
  }
  if ($pids.Count -gt 0 -and -not $owned) {
    throw "The running instance was started by the DSH-X launcher (PID $($pids -join ', ')); stop it from DSH-X instead."
  }
  if ($Intentional) { Set-Content -Path $StopMarker -Value ((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')) }
  foreach ($p in $pids) {
    Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
  }
  # Wait for exit (Stop-Process is synchronous); then drop the pid file.
  if (Test-Path $PidFile) { Remove-Item $PidFile -Force }
  if ($Intentional) { Write-Output 'dsh-superagent stopped. Automatic recovery is paused until start/restart.' }
  else { Write-Output 'dsh-superagent stopped.' }
}

if ($RespectStop -and ($Action -in @('start','restart')) -and (Test-Path $StopMarker)) {
  Write-Output 'Intentional stop is active; automatic recovery skipped.'
  exit 0
}
$code = 0
switch ($Action) {
  'status'  { $code = Show-Status }
  'stop'    { Stop-Service $true }
  'restart' { Stop-Service $false; $code = Start-Service }
  'start'   { $code = Start-Service }
}
exit $code
