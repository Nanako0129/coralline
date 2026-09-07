#Requires -Version 5.1
<#
.SYNOPSIS
  Statusline.ps1 render benchmark: concurrent n=1,2,4,8,16
  Measures wall-clock latency (ms) per render and aggregate CPU (user+sys of worker processes).

.EXAMPLE
  powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File tools\bench\bench-statusline.ps1
  powershell ... -File bench-statusline.ps1 -Statusline C:\path\statusline.ps1 -Renders 20
#>
param(
  [string]$RepoRoot = '',
  [string]$Statusline = '',
  [string]$Label = 'powershell',
  [int]$Renders = 20,
  [int[]]$Ns = @(1, 2, 4, 8, 16),
  [string]$Out = '',
  [switch]$KeepTmp
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $RepoRoot) {
  # tools/bench -> repo root
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  if (-not (Test-Path (Join-Path $RepoRoot 'statusline.ps1')) -and -not (Test-Path (Join-Path $RepoRoot 'statusline.sh'))) {
    # when script is copied alone next to statusline.ps1 under ~/.claude/coralline
    $RepoRoot = Split-Path -Parent $PSScriptRoot
  }
}
if (-not $Statusline) {
  $candidate = Join-Path $RepoRoot 'statusline.ps1'
  if (Test-Path -LiteralPath $candidate) {
    $Statusline = $candidate
  } else {
    $Statusline = Join-Path $env:USERPROFILE '.claude\coralline\statusline.ps1'
  }
}
if (-not (Test-Path -LiteralPath $Statusline)) {
  throw "statusline.ps1 not found: $Statusline"
}

$psExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$psVer = $PSVersionTable.PSVersion.ToString()
if (-not $Label) { $Label = "powershell-$psVer" }

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("coralline-bench-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp | Out-Null
$HomeIso = Join-Path $Tmp 'home'
$ClaudeDir = Join-Path $HomeIso '.claude\coralline'
$ThemesDst = Join-Path $ClaudeDir 'themes'
New-Item -ItemType Directory -Path $ThemesDst -Force | Out-Null

# Themes: from repo, or from installed coralline
$themeSrc = Join-Path $RepoRoot 'themes'
if (-not (Test-Path -LiteralPath $themeSrc)) {
  $themeSrc = Join-Path $env:USERPROFILE '.claude\coralline\themes'
}
if (Test-Path -LiteralPath $themeSrc) {
  Copy-Item -Path (Join-Path $themeSrc '*') -Destination $ThemesDst -Recurse -Force
}

$confPath = Join-Path $HomeIso '.claude\coralline.conf'
@'
. ~/.claude/coralline/themes/claude-coral.conf
VL_STYLE="pill"
VL_LAYOUT="fixed"
VL_SEGMENTS="dir git model ctx limit5h limit7d burn cost clock"
VL_LIMIT_SYNC=1
VL_CLOCK="24h"
VL_CLOCK_SECONDS=1
VL_FLOAT=0
'@ | Set-Content -LiteralPath $confPath -Encoding UTF8

# Build input JSON with real cwd + near-future resets
$cwdForGit = $RepoRoot
if (-not (Test-Path (Join-Path $cwdForGit '.git'))) {
  $cwdForGit = (Get-Location).Path
}
$now = [DateTime]::UtcNow
$rst5 = $now.AddHours(1).ToString("yyyy-MM-ddTHH:mm:ssZ")
$rst7 = $now.AddDays(3).ToString("yyyy-MM-ddTHH:mm:ssZ")
$payload = [ordered]@{
  cwd = $cwdForGit
  workspace = @{ current_dir = $cwdForGit }
  model = @{ display_name = 'Claude Fable 5' }
  output_style = @{ name = 'Explanatory' }
  effort = @{ level = 'high' }
  context_window = @{
    used_percentage = 62.4
    total_input_tokens = 1234567
    total_output_tokens = 45678
    current_usage = @{
      cache_read_input_tokens = 98765
      cache_creation_input_tokens = 4321
    }
  }
  rate_limits = @{
    five_hour = @{ used_percentage = 41.2; resets_at = $rst5 }
    seven_day = @{ used_percentage = 78.9; resets_at = $rst7 }
  }
  cost = @{
    total_cost_usd = 1.2345
    total_lines_added = 321
    total_lines_removed = 87
    total_duration_ms = 5432100
  }
}
$inputPath = Join-Path $Tmp 'input.json'
($payload | ConvertTo-Json -Depth 8 -Compress) | Set-Content -LiteralPath $inputPath -Encoding UTF8

# Env isolation for child processes
$isoEnv = @{
  HOME = $HomeIso
  USERPROFILE = $HomeIso
  CORALLINE_CONFIG = $confPath
}

function Invoke-StatuslineOnce {
  param([hashtable]$EnvMap)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $psExe
  $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Statusline`""
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  foreach ($k in $EnvMap.Keys) {
    $psi.EnvironmentVariables[$k] = [string]$EnvMap[$k]
  }
  # Also clear user profile pollution: point APPDATA under iso if needed
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $inText = [System.IO.File]::ReadAllText($inputPath)
  $p.StandardInput.Write($inText)
  $p.StandardInput.Close()
  $null = $p.StandardOutput.ReadToEnd()
  $stderrText = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  # A renderer that failed still returns in the expected shape and still takes a
  # plausible amount of time, so discarding the exit code publishes CSV rows for
  # an experiment that never ran: a parse error, a missing dependency, or a
  # state-store failure that only appears under concurrency all read as latency.
  # Abort instead, and surface the stderr that was previously thrown away.
  if ($p.ExitCode -ne 0) {
    throw ("statusline exited {0}: {1}" -f $p.ExitCode, $stderrText.Trim())
  }
  return $p
}

# Warmup. The return value matters here only for the exit-code check inside.
1..5 | ForEach-Object { [void](Invoke-StatuslineOnce -EnvMap $isoEnv) }

function Get-Percentile {
  param([double[]]$Values, [double]$P)
  $a = $Values | Sort-Object
  if ($a.Count -eq 0) { return 0 }
  if ($a.Count -eq 1) { return [double]$a[0] }
  $k = ($a.Count - 1) * ($P / 100.0)
  $f = [int][Math]::Floor($k)
  $c = [Math]::Min($f + 1, $a.Count - 1)
  if ($f -eq $c) { return [double]$a[$f] }
  return [double]$a[$f] + ([double]$a[$c] - [double]$a[$f]) * ($k - $f)
}

if (-not $Out) {
  $resultsDir = Join-Path $RepoRoot 'tools\bench\results'
  if (-not (Test-Path $resultsDir)) {
    # fallback under tmp parent if repo has no tools/bench
    $resultsDir = Join-Path $Tmp 'results'
  }
  New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
  $safeLabel = ($Label -replace '[\\/:*?"<>|]', '_')
  $Out = Join-Path $resultsDir ($safeLabel + '.csv')
}

$header = 'platform,label,shell,shell_version,n,renders_per_worker,total_renders,mean_ms,p50_ms,p95_ms,p99_ms,min_ms,max_ms,wall_s,user_s,sys_s,cpu_pct,cpu_s_per_render'
Set-Content -LiteralPath $Out -Value $header -Encoding UTF8

Write-Host "=== coralline statusline bench (PowerShell) ==="
Write-Host "label=$Label  statusline=$Statusline  ps=$psVer"
Write-Host "renders/worker=$Renders  ns=$($Ns -join ',')"
Write-Host "tmp=$Tmp"

foreach ($n in $Ns) {
  $latencies = New-Object System.Collections.Generic.List[double]
  # Split user and kernel the way the Bash arm's `time -p` does. System.Diagnostics
  # .Process exposes both directly, so the earlier note about Windows not splitting
  # them was wrong: user_s carried user+kernel while sys_s was written as a constant
  # zero, and anyone comparing user_s across platforms compared Bash's user-only
  # against a Windows total.
  #
  # These cover the spawned powershell.exe and not its descendants, so the git.exe
  # the renderer launches is excluded. Measured on the native x64 box: git.exe costs
  # 7.0 ms CPU per call against a reported 1816 ms per render, so the omission is
  # about 0.4%, well inside run-to-run noise. Closing it needs a Win32 job object,
  # which is more machinery than the gap justifies; what matters is that the gap is
  # written down rather than implied away. The Bash arm's `time -p` does include
  # descendants, so treat a sub-percent cross-platform CPU difference as unresolved
  # rather than real.
  $cpuUser = 0.0
  $cpuSys = 0.0

  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  # Waves of concurrent n processes, each process does $Renders renders sequentially.
  # Using runspaces for true concurrency under Windows PowerShell 5.1.
  $pool = [runspacefactory]::CreateRunspacePool(1, $n)
  $pool.Open()
  $workers = @()

  $scriptBlock = {
    param($psExe, $statusline, $inputPath, $homeIso, $confPath, $renders)
    $lats = New-Object System.Collections.Generic.List[double]
    $userTicks = 0L
    $privTicks = 0L
    for ($r = 0; $r -lt $renders; $r++) {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $psExe
      $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$statusline`""
      $psi.UseShellExecute = $false
      $psi.RedirectStandardInput = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.CreateNoWindow = $true
      $psi.EnvironmentVariables['HOME'] = $homeIso
      $psi.EnvironmentVariables['USERPROFILE'] = $homeIso
      $psi.EnvironmentVariables['CORALLINE_CONFIG'] = $confPath
      $p = New-Object System.Diagnostics.Process
      $p.StartInfo = $psi
      $t0 = [System.Diagnostics.Stopwatch]::StartNew()
      [void]$p.Start()
      $p.StandardInput.Write([System.IO.File]::ReadAllText($inputPath))
      $p.StandardInput.Close()
      $null = $p.StandardOutput.ReadToEnd()
      $errText = $p.StandardError.ReadToEnd()
      $p.WaitForExit()
      $t0.Stop()
      # Same reason as Invoke-StatuslineOnce: a failed render is not a sample.
      # Report it out of the runspace rather than throwing here, so the collector
      # can dispose every pipeline before aborting the run.
      if ($p.ExitCode -ne 0) {
        return @{ Latencies = @(); UserTicks = 0L; PrivTicks = 0L; Failed = $true; ExitCode = $p.ExitCode; Stderr = $errText.Trim() }
      }
      $lats.Add($t0.Elapsed.TotalMilliseconds)
      try {
        $userTicks += $p.UserProcessorTime.Ticks
        $privTicks += $p.PrivilegedProcessorTime.Ticks
      } catch {}
    }
    return @{ Latencies = $lats.ToArray(); UserTicks = $userTicks; PrivTicks = $privTicks; Failed = $false; ExitCode = 0; Stderr = '' }
  }

  for ($i = 0; $i -lt $n; $i++) {
    $ps = [powershell]::Create().AddScript($scriptBlock).AddArgument($psExe).AddArgument($Statusline).AddArgument($inputPath).AddArgument($HomeIso).AddArgument($confPath).AddArgument($Renders)
    $ps.RunspacePool = $pool
    $workers += @{ Pipe = $ps; Handle = $ps.BeginInvoke() }
  }
  $failure = ''
  foreach ($w in $workers) {
    $result = $w.Pipe.EndInvoke($w.Handle)
    $w.Pipe.Dispose()
    # EndInvoke returns Collection; first element is our hashtable
    $item = $result[0]
    if ($item.Failed) {
      if (-not $failure) { $failure = "statusline exited $($item.ExitCode): $($item.Stderr)" }
      continue
    }
    foreach ($ms in $item.Latencies) { $latencies.Add([double]$ms) }
    $cpuUser += [TimeSpan]::FromTicks([int64]$item.UserTicks).TotalSeconds
    $cpuSys  += [TimeSpan]::FromTicks([int64]$item.PrivTicks).TotalSeconds
  }
  $pool.Close()
  $pool.Dispose()
  if ($failure) { throw ("n=$n aborted, no CSV row written. " + $failure) }
  $sw.Stop()

  $arr = $latencies.ToArray()
  $mean = ($arr | Measure-Object -Average).Average
  if (-not $mean) { $mean = 0 }
  $p50 = Get-Percentile -Values $arr -P 50
  $p95 = Get-Percentile -Values $arr -P 95
  $p99 = Get-Percentile -Values $arr -P 99
  $min = ($arr | Measure-Object -Minimum).Minimum
  $max = ($arr | Measure-Object -Maximum).Maximum
  if (-not $min) { $min = 0 }
  if (-not $max) { $max = 0 }
  $count = $arr.Count
  $wall = $sw.Elapsed.TotalSeconds
  $cpuTotal = $cpuUser + $cpuSys
  $cpuPct = if ($wall -gt 0) { ($cpuTotal / $wall) * 100.0 } else { 0 }
  $cpuPer = if ($count -gt 0) { $cpuTotal / $count } else { 0 }
  $total = $n * $Renders

  $line = @(
    'Windows',
    $Label,
    $psExe,
    $psVer,
    $n,
    $Renders,
    $total,
    ('{0:F3}' -f $mean),
    ('{0:F3}' -f $p50),
    ('{0:F3}' -f $p95),
    ('{0:F3}' -f $p99),
    ('{0:F3}' -f $min),
    ('{0:F3}' -f $max),
    ('{0:F6}' -f $wall),
    ('{0:F3}' -f $cpuUser),
    ('{0:F3}' -f $cpuSys),
    ('{0:F1}' -f $cpuPct),
    ('{0:F6}' -f $cpuPer)
  ) -join ','
  Add-Content -LiteralPath $Out -Value $line -Encoding UTF8

  Write-Host ("n={0,-2}  mean={1,8:N3}ms  p50={2,8:N3}  p95={3,8:N3}  p99={4,8:N3}  wall={5:N3}s  cpu={6:N3}s  cpu%={7:N1}" -f `
    $n, $mean, $p50, $p95, $p99, $wall, $cpuTotal, $cpuPct)
}

Write-Host "CSV: $Out"

if (-not $KeepTmp) {
  try { Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
} else {
  Write-Host "kept tmp: $Tmp"
}

Write-Output $Out
