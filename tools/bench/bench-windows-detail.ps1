#Requires -Version 5.1
<#
  Detailed Windows statusline benchmark: spawn baseline, config matrix,
  concurrency n=1..16, memory samples. PowerShell + Git Bash. Isolates HOME.
#>
param(
  [string]$RepoRoot = 'C:\Users\Nanako\coralline-bench',
  [string]$StatuslinePs1 = '',
  [string]$StatuslineSh = '',
  [string]$GitBash = 'C:\Program Files\Git\bin\bash.exe',
  [int]$Samples = 30,
  [int]$ConcRenders = 15,
  [int[]]$Ns = @(1, 2, 4, 8, 16),
  [string]$OutDir = '',
  [switch]$SkipGitBash,
  [switch]$SkipConcurrency,
  [switch]$KeepTmp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ── fixed paths ──────────────────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $RepoRoot)) { throw "RepoRoot missing: $RepoRoot" }
# Both renderers default out of RepoRoot. Preferring the installed copy for one
# and RepoRoot for the other let the configuration and cross-runtime matrices
# compare two different versions on a machine that already has coralline
# installed, and report the difference as a property of the runtime.
if (-not $StatuslinePs1) { $StatuslinePs1 = Join-Path $RepoRoot 'statusline.ps1' }
if (-not $StatuslineSh) { $StatuslineSh = Join-Path $RepoRoot 'statusline.sh' }
if (-not (Test-Path -LiteralPath $StatuslinePs1)) { throw "missing statusline.ps1: $StatuslinePs1" }
if (-not $SkipGitBash -and -not (Test-Path -LiteralPath $StatuslineSh)) { throw "missing statusline.sh" }
if (-not $SkipGitBash -and -not (Test-Path -LiteralPath $GitBash)) {
  Write-Warning "Git Bash missing; skipping bash suite"
  $SkipGitBash = $true
}

$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $PsExe)) {
  $PsExe = (Get-Command powershell.exe -ErrorAction Stop).Source
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $RepoRoot 'tools\bench\results\windows-detail'
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$Work = Join-Path ([IO.Path]::GetTempPath()) ('coralline-wbench-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work -Force | Out-Null

function Remove-WorkTree {
  param([string]$Path, [bool]$Keep)
  if ($Keep) { Write-Host "kept $Path"; return }
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
  }
}

try {
# ── isolate home ─────────────────────────────────────────────────────────────
$HomeIso = Join-Path $Work 'home'
$ThemeDst = Join-Path $HomeIso '.claude\coralline\themes'
New-Item -ItemType Directory -Path $ThemeDst -Force | Out-Null
$themeSrc = Join-Path $RepoRoot 'themes'
if (-not (Test-Path $themeSrc)) { $themeSrc = Join-Path $env:USERPROFILE '.claude\coralline\themes' }
if (Test-Path $themeSrc) { Copy-Item (Join-Path $themeSrc '*') $ThemeDst -Recurse -Force }

$GitCwd = $RepoRoot
if (-not (Test-Path (Join-Path $GitCwd '.git'))) {
  $GitCwd = Join-Path $Work 'fake-repo'
  New-Item -ItemType Directory -Path $GitCwd -Force | Out-Null
  Push-Location $GitCwd
  try {
    & git init -q 2>$null | Out-Null
    'x' | Set-Content -LiteralPath (Join-Path $GitCwd 'README') -Encoding ascii
    & git add README 2>$null | Out-Null
    & git -c user.email=b@l -c user.name=b commit -q -m b 2>$null | Out-Null
  } finally { Pop-Location }
}
$NoGitCwd = Join-Path $Work 'not-a-repo'
New-Item -ItemType Directory -Path $NoGitCwd -Force | Out-Null

function New-BenchPayload([string]$Cwd) {
  $now = [DateTime]::UtcNow
  $o = [ordered]@{
    cwd = $Cwd
    workspace = @{ current_dir = $Cwd }
    model = @{ display_name = 'Claude Fable 5' }
    output_style = @{ name = 'Explanatory' }
    effort = @{ level = 'high' }
    context_window = @{
      used_percentage = 62.4
      total_input_tokens = 1234567
      total_output_tokens = 45678
      current_usage = @{ cache_read_input_tokens = 98765; cache_creation_input_tokens = 4321 }
    }
    rate_limits = @{
      five_hour = @{ used_percentage = 41.2; resets_at = $now.AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ') }
      seven_day = @{ used_percentage = 78.9; resets_at = $now.AddDays(3).ToString('yyyy-MM-ddTHH:mm:ssZ') }
    }
    cost = @{
      total_cost_usd = 1.2345; total_lines_added = 321; total_lines_removed = 87; total_duration_ms = 5432100
    }
  }
  return ($o | ConvertTo-Json -Depth 8 -Compress)
}

$PayloadGit = Join-Path $Work 'payload-git.json'
$PayloadNoGit = Join-Path $Work 'payload-nogit.json'
$utf8 = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllText($PayloadGit, (New-BenchPayload $GitCwd), $utf8)
[IO.File]::WriteAllText($PayloadNoGit, (New-BenchPayload $NoGitCwd), $utf8)

$Presets = [ordered]@{
  'minimal' = "VL_STYLE=`"pill`"`nVL_LAYOUT=`"fixed`"`nVL_SEGMENTS=`"model clock`"`nVL_LIMIT_SYNC=0`nVL_FLOAT=0`nVL_CLOCK=`"24h`"`nVL_CLOCK_SECONDS=0`n"
  'no-git' = "VL_STYLE=`"pill`"`nVL_LAYOUT=`"fixed`"`nVL_SEGMENTS=`"model ctx cost clock`"`nVL_LIMIT_SYNC=0`nVL_FLOAT=0`nVL_CLOCK=`"24h`"`nVL_CLOCK_SECONDS=1`n"
  'default-core' = "VL_STYLE=`"pill`"`nVL_LAYOUT=`"fixed`"`nVL_SEGMENTS=`"dir git model ctx cost clock`"`nVL_LIMIT_SYNC=0`nVL_FLOAT=0`nVL_CLOCK=`"24h`"`nVL_CLOCK_SECONDS=1`n"
  'with-limits' = "VL_STYLE=`"pill`"`nVL_LAYOUT=`"fixed`"`nVL_SEGMENTS=`"dir git model ctx limit5h limit7d cost clock`"`nVL_LIMIT_SYNC=1`nVL_FLOAT=0`nVL_CLOCK=`"24h`"`nVL_CLOCK_SECONDS=1`n"
  'full-burn' = "VL_STYLE=`"pill`"`nVL_LAYOUT=`"fixed`"`nVL_SEGMENTS=`"dir git model ctx limit5h limit7d burn cost clock`"`nVL_LIMIT_SYNC=1`nVL_FLOAT=0`nVL_CLOCK=`"24h`"`nVL_CLOCK_SECONDS=1`n"
  'production-like' = "VL_STYLE=`"pill`"`nVL_LAYOUT=`"auto`"`nVL_MAX_LINES=5`nVL_SEGMENTS=`"dir git node python model effort ctx limit5h limit7d burn cost clock`"`nVL_LIMIT_SYNC=1`nVL_FLOAT=0`nVL_CLOCK=`"12h`"`nVL_CLOCK_SECONDS=1`n"
}

function Set-BenchConf([string]$Name) {
  $conf = Join-Path $HomeIso '.claude\coralline.conf'
  $body = ". ~/.claude/coralline/themes/claude-coral.conf`n" + $Presets[$Name]
  [IO.File]::WriteAllText($conf, $body, $utf8)
  return $conf
}

function ConvertTo-UnixPath([string]$Win) {
  if ($Win -match '^([A-Za-z]):\\(.*)$') {
    return '/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/')
  }
  return ($Win -replace '\\', '/')
}

$BashHelper = Join-Path $Work 'run-sh.sh'
@(
  '#!/usr/bin/env bash'
  'set +e'
  'export PATH="/c/Program Files/Git/usr/bin:/c/Program Files/Git/bin:/c/Program Files/Git/mingw64/bin:${PATH:-}"'
  'export HOME="$1"'
  'export CORALLINE_CONFIG="$2"'
  'sl="$3"; in="$4"; mode="${5:-statusline}"'
  'if [ "$mode" = "true" ]; then true; exit $?; fi'
  '"$sl" < "$in" >/dev/null'
  'exit $?'
) -join "`n" | Set-Content -LiteralPath $BashHelper -Encoding ASCII -NoNewline
# ensure trailing newline for bash
Add-Content -LiteralPath $BashHelper -Value '' -Encoding ASCII

function Get-Pct([double[]]$a, [double]$p) {
  if (-not $a -or $a.Count -eq 0) { return 0.0 }
  $s = @($a | Sort-Object)
  if ($s.Count -eq 1) { return [double]$s[0] }
  $k = ($s.Count - 1) * $p / 100.0
  $f = [int][Math]::Floor($k)
  $c = [Math]::Min($f + 1, $s.Count - 1)
  if ($f -eq $c) { return [double]$s[$f] }
  return [double]$s[$f] + ([double]$s[$c] - [double]$s[$f]) * ($k - $f)
}

function New-Summary([double[]]$lat, [double]$wall, [double]$cpu, [long]$ws = 0, [long]$priv = 0) {
  $n = $lat.Count
  $mean = if ($n) { ($lat | Measure-Object -Average).Average } else { 0 }
  $min = if ($n) { ($lat | Measure-Object -Minimum).Minimum } else { 0 }
  $max = if ($n) { ($lat | Measure-Object -Maximum).Maximum } else { 0 }
  $cpuPct = if ($wall -gt 0) { $cpu / $wall * 100.0 } else { 0 }
  $cpuPer = if ($n -gt 0) { $cpu / $n } else { 0 }
  [pscustomobject]@{
    count = $n
    mean_ms = [math]::Round($mean, 3)
    p50_ms = [math]::Round((Get-Pct $lat 50), 3)
    p95_ms = [math]::Round((Get-Pct $lat 95), 3)
    p99_ms = [math]::Round((Get-Pct $lat 99), 3)
    min_ms = [math]::Round([double]$min, 3)
    max_ms = [math]::Round([double]$max, 3)
    wall_s = [math]::Round($wall, 6)
    cpu_s = [math]::Round($cpu, 6)
    cpu_pct = [math]::Round($cpuPct, 1)
    cpu_s_per_render = [math]::Round($cpuPer, 6)
    peak_ws_mb = [math]::Round($ws / 1MB, 2)
    peak_private_mb = [math]::Round($priv / 1MB, 2)
  }
}

function Invoke-PsEmpty {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $PsExe
  $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -Command "exit 0"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $p = New-Object Diagnostics.Process
  $p.StartInfo = $psi
  $sw = [Diagnostics.Stopwatch]::StartNew()
  [void]$p.Start()
  $null = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd()
  $p.WaitForExit(); $sw.Stop()
  $cpu = 0.0; try { $cpu = $p.TotalProcessorTime.TotalSeconds } catch {}
  [pscustomobject]@{ Ms = $sw.Elapsed.TotalMilliseconds; Cpu = $cpu }
}

function Invoke-PsStatusline {
  param([string]$InputPath, [string]$ConfPath, [switch]$Mem)
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $PsExe
  $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$StatuslinePs1`""
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['HOME'] = $HomeIso
  $psi.EnvironmentVariables['USERPROFILE'] = $HomeIso
  $psi.EnvironmentVariables['CORALLINE_CONFIG'] = $ConfPath
  $p = New-Object Diagnostics.Process
  $p.StartInfo = $psi
  $sw = [Diagnostics.Stopwatch]::StartNew()
  [void]$p.Start()
  $p.StandardInput.Write([IO.File]::ReadAllText($InputPath))
  $p.StandardInput.Close()
  $ws = 0L; $priv = 0L
  if ($Mem) {
    while (-not $p.HasExited) {
      try {
        $p.Refresh()
        if ($p.WorkingSet64 -gt $ws) { $ws = $p.WorkingSet64 }
        if ($p.PrivateMemorySize64 -gt $priv) { $priv = $p.PrivateMemorySize64 }
      } catch {}
      Start-Sleep -Milliseconds 2
    }
  }
  $null = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd()
  $p.WaitForExit(); $sw.Stop()
  $cpu = 0.0; try { $cpu = $p.TotalProcessorTime.TotalSeconds } catch {}
  [pscustomobject]@{ Ms = $sw.Elapsed.TotalMilliseconds; Cpu = $cpu; Ws = $ws; Priv = $priv; Code = $p.ExitCode }
}

function Invoke-BashHelper {
  param([string]$ConfPath = '', [string]$InputPath = '', [string]$Mode = 'statusline')
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $GitBash
  $h = ConvertTo-UnixPath $HomeIso
  $c = if ($ConfPath) { ConvertTo-UnixPath $ConfPath } else { '' }
  $s = ConvertTo-UnixPath $StatuslineSh
  $i = if ($InputPath) { ConvertTo-UnixPath $InputPath } else { '' }
  $helper = ConvertTo-UnixPath $BashHelper
  $psi.Arguments = "`"$helper`" `"$h`" `"$c`" `"$s`" `"$i`" $Mode"
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $p = New-Object Diagnostics.Process
  $p.StartInfo = $psi
  $sw = [Diagnostics.Stopwatch]::StartNew()
  [void]$p.Start()
  $null = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd()
  $p.WaitForExit(); $sw.Stop()
  $cpu = 0.0; try { $cpu = $p.TotalProcessorTime.TotalSeconds } catch {}
  [pscustomobject]@{ Ms = $sw.Elapsed.TotalMilliseconds; Cpu = $cpu; Code = $p.ExitCode }
}

# ── meta ─────────────────────────────────────────────────────────────────────
$machine = $env:COMPUTERNAME
if (-not $machine) { $machine = 'unknown' }
$cores = 0
try { $cores = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Measure-Object NumberOfLogicalProcessors -Sum).Sum } catch {}
$ramGb = 0
try { $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1GB, 1) } catch {}
$cpuName = ''
try { $cpuName = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Name) } catch {}

$meta = @"
time_utc=$([DateTime]::UtcNow.ToString('o'))
host=$machine
cpu=$cpuName
cores=$cores
ram_gb=$ramGb
ps_exe=$PsExe
ps_ver=$($PSVersionTable.PSVersion)
statusline_ps1=$StatuslinePs1
statusline_sh=$StatuslineSh
git_bash=$GitBash
samples=$Samples
conc_renders=$ConcRenders
ns=$($Ns -join ',')
git_cwd=$GitCwd
work=$Work
"@
$meta | Set-Content -LiteralPath (Join-Path $OutDir 'meta.txt') -Encoding UTF8

Write-Host "=== Windows detail bench ==="
Write-Host "host=$machine cores=$cores ram=${ramGb}GB"
Write-Host "ps=$PsExe"
Write-Host "ps1=$StatuslinePs1"
Write-Host "out=$OutDir"
Write-Host "work=$Work"

$rows = New-Object System.Collections.Generic.List[object]

function Add-Row {
  param($Suite, $Runtime, $Config, $Payload, $N, $Sum)
  $rows.Add([pscustomobject]@{
    suite = $Suite; runtime = $Runtime; config = $Config; payload = $Payload; n = $N
    mean_ms = $Sum.mean_ms; p50_ms = $Sum.p50_ms; p95_ms = $Sum.p95_ms; p99_ms = $Sum.p99_ms
    min_ms = $Sum.min_ms; max_ms = $Sum.max_ms; count = $Sum.count
    wall_s = $Sum.wall_s; cpu_s = $Sum.cpu_s; cpu_pct = $Sum.cpu_pct
    cpu_s_per_render = $Sum.cpu_s_per_render
    peak_ws_mb = $Sum.peak_ws_mb; peak_private_mb = $Sum.peak_private_mb
  }) | Out-Null
}

# ═══ A) spawn baselines ══════════════════════════════════════════════════════
Write-Host "`n--- A) spawn baselines ($Samples) ---"
$lat = New-Object Collections.Generic.List[double]
$cpu = 0.0
$sw = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $Samples; $i++) {
  $r = Invoke-PsEmpty
  $lat.Add($r.Ms); $cpu += $r.Cpu
}
$sw.Stop()
$s = New-Summary $lat.ToArray() $sw.Elapsed.TotalSeconds $cpu
Add-Row 'spawn-baseline' 'powershell' 'empty-exit0' 'none' 1 $s
Write-Host ("PS empty-exit0   mean={0}ms p50={1} p95={2}" -f $s.mean_ms, $s.p50_ms, $s.p95_ms)
$PsSpawnMean = $s.mean_ms

$BashSpawnMean = 0
if (-not $SkipGitBash) {
  $lat = New-Object Collections.Generic.List[double]
  $cpu = 0.0
  $sw = [Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt $Samples; $i++) {
    $r = Invoke-BashHelper -Mode 'true'
    $lat.Add($r.Ms); $cpu += $r.Cpu
  }
  $sw.Stop()
  $s = New-Summary $lat.ToArray() $sw.Elapsed.TotalSeconds $cpu
  Add-Row 'spawn-baseline' 'git-bash' 'true' 'none' 1 $s
  Write-Host ("SH true          mean={0}ms p50={1} p95={2}" -f $s.mean_ms, $s.p50_ms, $s.p95_ms)
  $BashSpawnMean = $s.mean_ms
}

# ═══ B) config matrix ════════════════════════════════════════════════════════
Write-Host "`n--- B) config matrix ($Samples each) ---"
$matrix = @(
  @{ name = 'minimal';         payload = 'git';   path = $PayloadGit }
  @{ name = 'no-git';          payload = 'nogit'; path = $PayloadNoGit }
  @{ name = 'default-core';    payload = 'git';   path = $PayloadGit }
  @{ name = 'with-limits';     payload = 'git';   path = $PayloadGit }
  @{ name = 'full-burn';       payload = 'git';   path = $PayloadGit }
  @{ name = 'production-like'; payload = 'git';   path = $PayloadGit }
)

foreach ($m in $matrix) {
  $conf = Set-BenchConf $m.name
  1..3 | ForEach-Object { [void](Invoke-PsStatusline -InputPath $m.path -ConfPath $conf) }

  $lat = New-Object Collections.Generic.List[double]
  $cpu = 0.0; $ws = 0L; $priv = 0L
  $sw = [Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt $Samples; $i++) {
    $mem = ($i -lt 5)
    $r = Invoke-PsStatusline -InputPath $m.path -ConfPath $conf -Mem:$mem
    $lat.Add($r.Ms); $cpu += $r.Cpu
    if ($r.Ws -gt $ws) { $ws = $r.Ws }
    if ($r.Priv -gt $priv) { $priv = $r.Priv }
  }
  $sw.Stop()
  $s = New-Summary $lat.ToArray() $sw.Elapsed.TotalSeconds $cpu $ws $priv
  Add-Row 'config-matrix' 'powershell' $m.name $m.payload 1 $s
  $net = [math]::Round($s.mean_ms - $PsSpawnMean, 1)
  Write-Host ("PS  {0,-16} mean={1,8}ms net≈{2,7}ms p95={3,8} cpu/r={4:N3}s ws={5}MB" -f `
    $m.name, $s.mean_ms, $net, $s.p95_ms, $s.cpu_s_per_render, $s.peak_ws_mb)

  if (-not $SkipGitBash) {
    1..3 | ForEach-Object { [void](Invoke-BashHelper -ConfPath $conf -InputPath $m.path -Mode statusline) }
    $lat = New-Object Collections.Generic.List[double]
    $cpu = 0.0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Samples; $i++) {
      $r = Invoke-BashHelper -ConfPath $conf -InputPath $m.path -Mode statusline
      $lat.Add($r.Ms); $cpu += $r.Cpu
    }
    $sw.Stop()
    $s = New-Summary $lat.ToArray() $sw.Elapsed.TotalSeconds $cpu
    Add-Row 'config-matrix' 'git-bash' $m.name $m.payload 1 $s
    $net = [math]::Round($s.mean_ms - $BashSpawnMean, 1)
    Write-Host ("SH  {0,-16} mean={1,8}ms net≈{2,7}ms p95={3,8} cpu/r={4:N3}s" -f `
      $m.name, $s.mean_ms, $net, $s.p95_ms, $s.cpu_s_per_render)
  }
}

# ═══ C) concurrency ══════════════════════════════════════════════════════════
if (-not $SkipConcurrency) {
  Write-Host "`n--- C) concurrency (production-like, $ConcRenders/worker) ---"
  $conf = Set-BenchConf 'production-like'
  $inputPath = $PayloadGit
  $rtList = @('powershell')
  if (-not $SkipGitBash) { $rtList += 'git-bash' }

  foreach ($rt in $rtList) {
    foreach ($n in $Ns) {
      $lat = New-Object Collections.Generic.List[double]
      $cpuTotal = 0.0
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max($n, 1))
      $pool.Open()
      $workers = @()

      if ($rt -eq 'powershell') {
        $sb = {
          param($exe, $sl, $inp, $homeIsoPath, $conf, $renders)
          $L = New-Object Collections.Generic.List[double]
          $C = 0.0
          for ($r = 0; $r -lt $renders; $r++) {
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $exe
            $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$sl`""
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $psi.EnvironmentVariables['HOME'] = $homeIsoPath
            $psi.EnvironmentVariables['USERPROFILE'] = $homeIsoPath
            $psi.EnvironmentVariables['CORALLINE_CONFIG'] = $conf
            $p = New-Object Diagnostics.Process
            $p.StartInfo = $psi
            $t = [Diagnostics.Stopwatch]::StartNew()
            [void]$p.Start()
            $p.StandardInput.Write([IO.File]::ReadAllText($inp))
            $p.StandardInput.Close()
            $null = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd()
            $p.WaitForExit(); $t.Stop()
            $L.Add($t.Elapsed.TotalMilliseconds)
            try { $C += $p.TotalProcessorTime.TotalSeconds } catch {}
          }
          ,@{ Lat = $L.ToArray(); Cpu = $C }
        }
        for ($i = 0; $i -lt $n; $i++) {
          $ps = [powershell]::Create().AddScript($sb).AddArgument($PsExe).AddArgument($StatuslinePs1).AddArgument($inputPath).AddArgument($HomeIso).AddArgument($conf).AddArgument($ConcRenders)
          $ps.RunspacePool = $pool
          $workers += @{ P = $ps; H = $ps.BeginInvoke() }
        }
      } else {
        $helperU = ConvertTo-UnixPath $BashHelper
        $homeIsoU = ConvertTo-UnixPath $HomeIso
        $confU = ConvertTo-UnixPath $conf
        $slU = ConvertTo-UnixPath $StatuslineSh
        $inU = ConvertTo-UnixPath $inputPath
        $sb = {
          param($bash, $helper, $homeIsoPath, $conf, $sl, $inp, $renders)
          $L = New-Object Collections.Generic.List[double]
          $C = 0.0
          for ($r = 0; $r -lt $renders; $r++) {
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $bash
            $psi.Arguments = "`"$helper`" `"$homeIsoPath`" `"$conf`" `"$sl`" `"$inp`" statusline"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $p = New-Object Diagnostics.Process
            $p.StartInfo = $psi
            $t = [Diagnostics.Stopwatch]::StartNew()
            [void]$p.Start()
            $null = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd()
            $p.WaitForExit(); $t.Stop()
            $L.Add($t.Elapsed.TotalMilliseconds)
            try { $C += $p.TotalProcessorTime.TotalSeconds } catch {}
          }
          ,@{ Lat = $L.ToArray(); Cpu = $C }
        }
        for ($i = 0; $i -lt $n; $i++) {
          $ps = [powershell]::Create().AddScript($sb).AddArgument($GitBash).AddArgument($helperU).AddArgument($homeIsoU).AddArgument($confU).AddArgument($slU).AddArgument($inU).AddArgument($ConcRenders)
          $ps.RunspacePool = $pool
          $workers += @{ P = $ps; H = $ps.BeginInvoke() }
        }
      }

      foreach ($w in $workers) {
        $res = $w.P.EndInvoke($w.H)
        $w.P.Dispose()
        $item = $res[0]
        foreach ($ms in $item.Lat) { $lat.Add([double]$ms) }
        $cpuTotal += [double]$item.Cpu
      }
      $pool.Close(); $pool.Dispose()
      $sw.Stop()

      $s = New-Summary $lat.ToArray() $sw.Elapsed.TotalSeconds $cpuTotal
      Add-Row 'concurrency' $rt 'production-like' 'git' $n $s
      $risk = if ($s.mean_ms -gt 1000) { 'BACKLOG' } elseif ($s.p95_ms -gt 1000) { 'P95-RISK' } else { 'ok' }
      Write-Host ("{0,-11} n={1,-2} mean={2,8}ms p50={3,8} p95={4,8} p99={5,8} wall={6:N1}s cpu%={7} {8}" -f `
        $rt, $n, $s.mean_ms, $s.p50_ms, $s.p95_ms, $s.p99_ms, $s.wall_s, $s.cpu_pct, $risk)
    }
  }
}

# ═══ write ═══════════════════════════════════════════════════════════════════
$allCsv = Join-Path $OutDir 'all.csv'
$seqCsv = Join-Path $OutDir 'sequential.csv'
$concCsv = Join-Path $OutDir 'concurrency.csv'
$rows | Export-Csv -LiteralPath $allCsv -NoTypeInformation -Encoding UTF8
@($rows | Where-Object { $_.suite -ne 'concurrency' }) | Export-Csv -LiteralPath $seqCsv -NoTypeInformation -Encoding UTF8
@($rows | Where-Object { $_.suite -eq 'concurrency' }) | Export-Csv -LiteralPath $concCsv -NoTypeInformation -Encoding UTF8

Write-Host "`n--- spawn-subtracted (config matrix net cost) ---"
foreach ($r in @($rows | Where-Object { $_.suite -eq 'config-matrix' })) {
  $base = if ($r.runtime -eq 'powershell') { $PsSpawnMean } else { $BashSpawnMean }
  Write-Host ("{0,-11} {1,-16} gross={2,8}ms  spawn≈{3,6}ms  net≈{4,7}ms" -f `
    $r.runtime, $r.config, $r.mean_ms, [math]::Round($base,1), [math]::Round($r.mean_ms - $base, 1))
}

Write-Host "`nCSV: $allCsv"
Write-Output $allCsv

} finally {
  Remove-WorkTree -Path $Work -Keep:$KeepTmp.IsPresent
}
