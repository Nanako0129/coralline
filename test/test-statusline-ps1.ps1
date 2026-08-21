#Requires -Version 5.1
<#
  WIN-01 plus WIN-02 state regression and differential tests for statusline.ps1.

  Run on native Windows PowerShell 5.1. Git Bash is test-only and supplies the
  statusline.sh oracle plus real configure.sh printf %q fixtures.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Here = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Repo = Split-Path -Path $Here -Parent
$Script = Join-Path $Repo 'statusline.ps1'
$BashScript = Join-Path $Repo 'statusline.sh'
$script:StateScript = $Script
$script:StateBashScript = $BashScript
$Configure = Join-Path $Repo 'configure.sh'
$PowerShellExe = (Get-Process -Id $PID).Path
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('coralline-win01-test-' + [guid]::NewGuid().ToString('N'))
$script:Fail = 0
$script:Pass = 0
$script:Blocked = 0

function Glyph([int]$Codepoint) { return [System.Char]::ConvertFromUtf32($Codepoint) }

function Check([string]$Name, [bool]$Condition) {
    if ($Condition) { [Console]::Out.WriteLine("PASS  $Name"); $script:Pass++ }
    else { [Console]::Out.WriteLine("FAIL  $Name"); $script:Fail++ }
}

function Blocked([string]$Name, [string]$Reason) {
    [Console]::Out.WriteLine("BLOCKED  ${Name}: $Reason")
    $script:Blocked++
}

function Write-Utf8([string]$Path, [string]$Text) {
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Forward-Path([string]$Path) { return $Path.Replace('\', '/') }

function Invoke-CapturedProcess(
    [string]$FileName,
    [string]$Arguments,
    [string]$InputText,
    [hashtable]$Environment,
    [string]$WorkingDirectory,
    [int]$TimeoutMs,
    [byte[]]$InputBytes
) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) { [void]$psi.EnvironmentVariables.Remove($key) }
        else { $psi.EnvironmentVariables[$key] = [string]$Environment[$key] }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw 'process did not start' }
        $stdout = New-Object System.IO.MemoryStream
        $stderr = New-Object System.IO.MemoryStream
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        if ($null -eq $InputBytes) { $InputBytes = $Utf8NoBom.GetBytes($InputText) }
        if ($InputBytes.Length -gt 0) { $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length) }
        $process.StandardInput.Close()
        $timedOut = -not $process.WaitForExit($TimeoutMs)
        if ($timedOut) {
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(2000)
        }
        [void]$outTask.Wait(2000)
        [void]$errTask.Wait(2000)
        $watch.Stop()
        $outBytes = $stdout.ToArray()
        $errBytes = $stderr.ToArray()
        try { $outText = $StrictUtf8.GetString($outBytes) } catch { $outText = $null }
        try { $errText = $StrictUtf8.GetString($errBytes) } catch { $errText = $null }
        $exitCode = -1
        if (-not $timedOut -and $process.HasExited) { $exitCode = $process.ExitCode }
        return [pscustomobject]@{
            ExitCode = $exitCode
            TimedOut = $timedOut
            ElapsedMs = $watch.ElapsedMilliseconds
            StdoutBytes = $outBytes
            StderrBytes = $errBytes
            Stdout = $outText
            Stderr = $errText
        }
    } catch {
        $watch.Stop()
        return [pscustomobject]@{
            ExitCode = -1
            TimedOut = $false
            ElapsedMs = $watch.ElapsedMilliseconds
            StdoutBytes = [byte[]]@()
            StderrBytes = $Utf8NoBom.GetBytes($_.Exception.Message)
            Stdout = ''
            Stderr = $_.Exception.Message
        }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Start-CapturedProcessAsync(
    [string]$FileName,
    [string]$Arguments,
    [string]$InputText,
    [hashtable]$Environment,
    [string]$WorkingDirectory
) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) { [void]$psi.EnvironmentVariables.Remove($key) }
        else { $psi.EnvironmentVariables[$key] = [string]$Environment[$key] }
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw 'async process did not start' }
    $stdout = New-Object System.IO.MemoryStream
    $stderr = New-Object System.IO.MemoryStream
    $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
    $inputBytes = $Utf8NoBom.GetBytes($InputText)
    if ($inputBytes.Length -gt 0) { $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length) }
    $process.StandardInput.Close()
    return [pscustomobject]@{ Process=$process; Stdout=$stdout; Stderr=$stderr; OutTask=$outTask; ErrTask=$errTask }
}

function Wait-CapturedProcessAsync($Handle, [int]$TimeoutMs) {
    $timedOut = -not $Handle.Process.WaitForExit($TimeoutMs)
    if ($timedOut) { try { $Handle.Process.Kill() } catch { }; [void]$Handle.Process.WaitForExit(2000) }
    [void]$Handle.OutTask.Wait(2000); [void]$Handle.ErrTask.Wait(2000)
    $exitCode = -1
    if (-not $timedOut -and $Handle.Process.HasExited) { $exitCode = $Handle.Process.ExitCode }
    $stdoutBytes = $Handle.Stdout.ToArray()
    $stderrBytes = $Handle.Stderr.ToArray()
    try { $stdoutText = $StrictUtf8.GetString($stdoutBytes) } catch { $stdoutText = $null }
    try { $stderrText = $StrictUtf8.GetString($stderrBytes) } catch { $stderrText = $null }
    $result = [pscustomobject]@{ ExitCode=$exitCode; TimedOut=$timedOut; StdoutBytes=$stdoutBytes; StderrBytes=$stderrBytes; Stdout=$stdoutText; Stderr=$stderrText }
    $Handle.Process.Dispose(); $Handle.Stdout.Dispose(); $Handle.Stderr.Dispose()
    return $result
}

function Runtime-Environment([string]$ConfigPath, [hashtable]$Extra) {
    $runtimeHome = Join-Path $TempRoot 'runtime-home'
    $environment = @{
        HOME = Forward-Path $runtimeHome
        USERPROFILE = $runtimeHome
        CORALLINE_CONFIG = $null
        CORALLINE_NO_SAMPLE = '1'
        CORALLINE_TEST_NOW = $null
        REMORA_ACTIVE = $null
        VIRTUAL_ENV = $null
        CONDA_DEFAULT_ENV = $null
    }
    if (-not [string]::IsNullOrEmpty($ConfigPath)) { $environment.CORALLINE_CONFIG = Forward-Path $ConfigPath }
    foreach ($key in $Extra.Keys) { $environment[$key] = $Extra[$key] }
    return $environment
}

function Invoke-Statusline(
    [string]$Json,
    [string]$ConfigPath,
    [hashtable]$ExtraEnvironment,
    [string]$Arguments,
    [int]$TimeoutMs
) {
    $runtimeScript = $Script
    if ($ExtraEnvironment.ContainsKey('CORALLINE_TEST_WIDTH_SCRIPT') -and $null -ne $ExtraEnvironment.CORALLINE_TEST_WIDTH_SCRIPT) { $runtimeScript = $script:WidthScript }
    elseif ($ExtraEnvironment.ContainsKey('CORALLINE_TEST_FLOAT_SCRIPT') -and $null -ne $ExtraEnvironment.CORALLINE_TEST_FLOAT_SCRIPT) { $runtimeScript = $script:FloatScript }
    elseif ($ExtraEnvironment.ContainsKey('CORALLINE_TEST_NOW') -and $null -ne $ExtraEnvironment.CORALLINE_TEST_NOW) { $runtimeScript = $script:StateScript }
    $psArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $runtimeScript + '"'
    if (-not [string]::IsNullOrEmpty($Arguments)) { $psArgs += ' ' + $Arguments }
    return Invoke-CapturedProcess $PowerShellExe $psArgs $Json (Runtime-Environment $ConfigPath $ExtraEnvironment) $Repo $TimeoutMs
}

function Invoke-StatuslineBytes(
    [byte[]]$Bytes,
    [string]$ConfigPath,
    [hashtable]$ExtraEnvironment,
    [string]$Arguments,
    [int]$TimeoutMs
) {
    $psArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Script + '"'
    if (-not [string]::IsNullOrEmpty($Arguments)) { $psArgs += ' ' + $Arguments }
    return Invoke-CapturedProcess $PowerShellExe $psArgs '' (Runtime-Environment $ConfigPath $ExtraEnvironment) $Repo $TimeoutMs $Bytes
}

function Invoke-BashStatusline([string]$Json, [string]$ConfigPath, [hashtable]$ExtraEnvironment) {
    $environment = Runtime-Environment $ConfigPath $ExtraEnvironment
    $runtimeScript = $BashScript
    if ($ExtraEnvironment.ContainsKey('CORALLINE_TEST_NOW') -and $null -ne $ExtraEnvironment.CORALLINE_TEST_NOW) { $runtimeScript = $script:StateBashScript }
    $args = '--noprofile --norc "' + (Forward-Path $runtimeScript) + '"'
    return Invoke-CapturedProcess $script:BashExe $args $Json $environment $Repo 10000
}

function Invoke-BashSubagent([string]$Json, [string]$ConfigPath, [hashtable]$ExtraEnvironment) {
    $environment = Runtime-Environment $ConfigPath $ExtraEnvironment
    $args = '--noprofile --norc "' + (Forward-Path $BashScript) + '" --subagent'
    return Invoke-CapturedProcess $script:BashExe $args $Json $environment $Repo 10000
}

function Invoke-Subagent([string]$Json, [string]$ConfigPath, [hashtable]$ExtraEnvironment) {
    return Invoke-Statusline $Json $ConfigPath $ExtraEnvironment '--subagent' 15000
}

function Get-SubagentRows($Run) {
    $rows = New-Object 'System.Collections.Generic.List[object]'
    if ([string]::IsNullOrEmpty($Run.Stdout)) { return }
    foreach ($line in $Run.Stdout.Split(@("`n"), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        [void]$rows.Add(($line | ConvertFrom-Json -ErrorAction Stop))
    }
    return $rows.ToArray()
}

function New-SubagentNodePayload([int]$JunkCount) {
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('{"junk":[')
    for ($i=0; $i -lt $JunkCount; $i++) {
        if ($i -gt 0) { [void]$builder.Append(',') }
        [void]$builder.Append('null')
    }
    [void]$builder.Append('],"tasks":[{"id":"node-cap","name":"node-cap"}]}')
    return $builder.ToString()
}

function New-SubagentDepthPayload([int]$ArrayDepth) {
    $open = (('[' * $ArrayDepth) -join '')
    $close = ((']' * $ArrayDepth) -join '')
    return '{"junk":' + $open + 'null' + $close + ',"tasks":[{"id":"depth-cap","name":"depth-cap"}]}'
}

function Check-Run([string]$Name, $Run) {
    Check "$Name no timeout" (-not $Run.TimedOut)
    Check "$Name exit 0" ($Run.ExitCode -eq 0)
    Check "$Name stderr empty" ($Run.StderrBytes.Length -eq 0)
    Check "$Name strict UTF-8 stdout" ($null -ne $Run.Stdout)
    if ($Run.TimedOut -or $Run.ExitCode -ne 0 -or $Run.StderrBytes.Length -ne 0) {
        [Console]::Out.WriteLine('DIAG  ' + $Name + ' stderr=' + [Convert]::ToBase64String($Run.StderrBytes))
    }
}

function Plain([string]$Text) {
    if ($null -eq $Text) { return '' }
    return [regex]::Replace($Text, ([string][char]27 + '\[[0-9;]*m'), '')
}

function Check-Exact([string]$Name, $Actual, $Expected) {
    $equal = $Actual.StdoutBytes.Length -eq $Expected.StdoutBytes.Length
    if ($equal) {
        for ($i=0; $i -lt $Actual.StdoutBytes.Length; $i++) {
            if ($Actual.StdoutBytes[$i] -ne $Expected.StdoutBytes[$i]) { $equal = $false; break }
        }
    }
    Check $Name $equal
    if (-not $equal) {
        [Console]::Out.WriteLine('DIAG  PowerShell=' + [Convert]::ToBase64String($Actual.StdoutBytes))
        [Console]::Out.WriteLine('DIAG  Bash=' + [Convert]::ToBase64String($Expected.StdoutBytes))
    }
}

function New-Config([string]$Name, [string[]]$Lines) {
    $path = Join-Path $TempRoot ('config\' + $Name + '.conf')
    Write-Utf8 $path (($Lines -join "`n") + "`n")
    return $path
}

function New-Payload([string]$Cwd) {
    $payload = [ordered]@{
        cwd = $Cwd
        workspace = [ordered]@{ current_dir = $Cwd }
        model = [ordered]@{ display_name = 'Claude MODEL_SENTINEL' }
        output_style = [ordered]@{ name = 'Explanatory' }
        effort = [ordered]@{ level = 'high' }
        context_window = [ordered]@{
            used_percentage = 62.4
            total_input_tokens = 1234567
            total_output_tokens = 45678
            current_usage = [ordered]@{
                cache_read_input_tokens = 98765
                cache_creation_input_tokens = 4321
            }
        }
        rate_limits = [ordered]@{
            five_hour = [ordered]@{ used_percentage = 41.2; resets_at = '' }
            seven_day = [ordered]@{ used_percentage = 78.9; resets_at = '' }
        }
        cost = [ordered]@{
            total_cost_usd = 1.2345
            total_lines_added = 321
            total_lines_removed = 87
            total_duration_ms = 5432100
        }
    }
    return $payload
}

function Json($Object) { return ($Object | ConvertTo-Json -Compress -Depth 12) }
function Clone-Object($Object) { return ((Json $Object) | ConvertFrom-Json) }

function Run-ModelColor([string]$Name, [string]$ConfigPath, [string]$ExpectedSpec, [hashtable]$Environment) {
    $payload = New-Payload ''
    $run = Invoke-Statusline (Json $payload) $ConfigPath $Environment '' 5000
    Check-Run $Name $run
    if ($ExpectedSpec.Contains(',')) {
        $parts = $ExpectedSpec.Split(',')
        $needle = "48;2;$($parts[0]);$($parts[1]);$($parts[2])m"
    } else { $needle = "48;5;${ExpectedSpec}m" }
    $hasColor = $run.Stdout.Contains($needle)
    Check "$Name expected model color" $hasColor
    if (-not $hasColor) {
        [Console]::Out.WriteLine('DIAG  ' + $Name + '=' + [Convert]::ToBase64String($run.StdoutBytes))
        [Console]::Out.WriteLine('DIAG  config=' + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ConfigPath)))
    }
    return $run
}

function Snapshot-File([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path))).Replace('-', '') }
    finally { $sha.Dispose() }
    $info = New-Object System.IO.FileInfo($Path)
    return "$($info.Length)|$($info.LastWriteTimeUtc.Ticks)|$hash"
}

function Snapshot-Ads([string]$Carrier, [string]$StreamName) {
    try {
        $item = Get-Item -LiteralPath $Carrier -Stream $StreamName -ErrorAction Stop
        $bytes = [byte[]]@(Get-Content -LiteralPath $Carrier -Stream $StreamName -Encoding Byte -ErrorAction Stop)
    } catch { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
    return "$($item.Length)|$hash"
}

function Snapshot-StateTree([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return '<missing>' }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($Root.Length).Replace('\','/')
        $length = 0L
        if (-not $item.PSIsContainer) { $length = $item.Length }
        [void]$lines.Add(('{0}|{1}|{2}|{3}|{4}|{5}' -f $relative,$item.Attributes,$length,$item.CreationTimeUtc.Ticks,$item.LastWriteTimeUtc.Ticks,$item.LastAccessTimeUtc.Ticks))
    }
    return $lines -join "`n"
}

function Get-ImmediateNames([string]$Root) {
    if (-not [IO.Directory]::Exists($Root)) { return ,([string[]]@()) }
    return ,([string[]]@([IO.Directory]::EnumerateFileSystemEntries($Root) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object))
}

function Run-Git([string]$WorkingDirectory, [string]$Arguments) {
    $run = Invoke-CapturedProcess $script:GitExe $Arguments '' @{} $WorkingDirectory 10000
    if ($run.TimedOut -or $run.ExitCode -ne 0) { throw "git failed: $Arguments`n$($run.Stderr)" }
    return $run
}

function Quote-FromConfigure([string]$Value) {
    $environment = @{
        CORALLINE_CONFIGURE = (Forward-Path $Configure)
        CORALLINE_Q_VALUE = $Value
    }
    $run = Invoke-CapturedProcess $script:BashExe ('--noprofile --norc "' + (Forward-Path $script:QuoteHelper) + '"') '' $environment $Repo 5000
    if ($run.ExitCode -ne 0 -or $run.TimedOut -or $run.StderrBytes.Length -ne 0) { throw 'configure.sh shell_quote fixture failed' }
    return $run.Stdout
}

function Assert-NoUnexpectedResidue([string]$Root, [string]$Name) {
    $bad = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like '*.tmp' -or $_.Name -like '*.lock' -or $_.Name -like 'burn-*.tsv' -or $_.Name -like 'limit-*.d'
    })
    Check "$Name no runtime residue" ($bad.Count -eq 0)
}

function New-FloatConfig([string]$Name, [string]$Target, [string]$Segments, [string]$Separator, [string[]]$Extra) {
    $lines = @(('VL_SEGMENTS=' + (Quote-FromConfigure 'model ctx cost')), 'VL_CLOCK=off', 'VL_FLOAT=1', ('VL_FLOAT_SEGMENTS=' + (Quote-FromConfigure $Segments)), ('VL_FLOAT_FILE=' + (Quote-FromConfigure $Target)), ('VL_FLOAT_SEP=' + (Quote-FromConfigure $Separator)))
    if ($null -ne $Extra) { $lines += $Extra }
    return New-Config $Name $lines
}

function Invoke-Float([string]$Json, [string]$ConfigPath, [hashtable]$Extra) {
    return Invoke-Statusline $Json $ConfigPath $Extra '' 10000
}

function Wait-Ready([string]$Barrier, [int]$TimeoutMs) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        if (@([IO.Directory]::GetFiles([IO.Path]::GetDirectoryName($Barrier), ([IO.Path]::GetFileName($Barrier) + '.*.ready'))).Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 10
    }
    return $false
}

function Float-Bytes([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    return [IO.File]::ReadAllBytes($Path)
}

function Bytes-Same([byte[]]$Left, [byte[]]$Right) {
    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) { return $false }
    for ($i=0; $i -lt $Left.Length; $i++) { if ($Left[$i] -ne $Right[$i]) { return $false } }
    return $true
}

function Start-FloatAsync([string]$Json, [string]$ConfigPath, [hashtable]$Extra) {
    $psArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script:FloatScript + '"'
    return Start-CapturedProcessAsync $PowerShellExe $psArgs $Json (Runtime-Environment $ConfigPath $Extra) $Repo
}

[void][System.IO.Directory]::CreateDirectory($TempRoot)
$cleanupOk = $false
try {
    $source = [System.IO.File]::ReadAllText($Script, $StrictUtf8)
    $bashSource = [System.IO.File]::ReadAllText($BashScript, $StrictUtf8)

    # Deterministic clock and state capture live only in test copies. Production
    # has no hidden environment-controlled time or I/O hooks.
    $script:StateScript = Join-Path $TempRoot 'statusline-state-test.ps1'
    $psClock = '$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()'
    $psClockHook = @'
$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$testNowValue = 0L
if ([string]$env:CORALLINE_TEST_STRICT -eq '1') { $ErrorActionPreference = 'Stop' }
if ([string]$env:CORALLINE_TEST_NOW -match '\A(?:0|[1-9][0-9]{0,11})\z' -and [long]::TryParse([string]$env:CORALLINE_TEST_NOW, $IntegerStyle, $Invariant, [ref]$testNowValue) -and $testNowValue -le 253402300799L) { $Now = $testNowValue }
'@
    $psDumpMarker = '    $State = Get-CorallineState $BurnStateGate $Limit5StateGate $Limit7StateGate'
    $psDumpHook = @'
    $State = Get-CorallineState $BurnStateGate $Limit5StateGate $Limit7StateGate
    if (-not [string]::IsNullOrEmpty([string]$env:CORALLINE_TEST_STATE_DUMP)) {
        $capture = [ordered]@{
            BurnState=$State.Burn.State; BurnLabel=$State.Burn.Label; BurnEta=$State.Burn.Eta; BurnRate=$State.Burn.Rate; BurnTtr=$State.Burn.Ttr
            FiveState=$State.Five.State; FiveEta=$State.Five.Eta; FiveRate=$State.Five.Rate; FiveTtr=$State.Five.Ttr
            SevenEta=$State.Seven.Eta; SevenRate=$State.Seven.Rate; SevenTtr=$State.Seven.Ttr
            Limit5Valid=$State.Limit5.Valid; Limit5Reset=$State.Limit5.Reset; Limit5Pct=$State.Limit5.Pct
            Limit7Valid=$State.Limit7.Valid; Limit7Reset=$State.Limit7.Reset; Limit7Pct=$State.Limit7.Pct
            BurnSnapshotComplete=$State.BurnSnapshotComplete; Limit5SnapshotComplete=$State.Limit5SnapshotComplete; Limit7SnapshotComplete=$State.Limit7SnapshotComplete
        }
        [IO.File]::WriteAllText([string]$env:CORALLINE_TEST_STATE_DUMP, ($capture | ConvertTo-Json -Compress), $Utf8NoBom)
    }
'@
    $psMathMarker = 'function Format-StatePct([int]$Milli) {'
    $psMathHook = @'
if (-not [string]::IsNullOrEmpty([string]$env:CORALLINE_TEST_MATH_DUMP)) {
    $values = @(
        (Get-RoundEvenInt64 5L 2L),
        (Get-RoundEvenInt64 7L 2L),
        (Get-RoundEvenInt64 4L 3L),
        (Get-RoundEvenInt64 5L 3L),
        (Format-StateRate 10000000000L 3L),
        (Format-StateRate 19999999999L 2L),
        (Get-RoundEvenInt64 8639913600L 1000L)
    )
    [IO.File]::WriteAllText([string]$env:CORALLINE_TEST_MATH_DUMP, ($values -join '|'), $Utf8NoBom)
    [Environment]::Exit(0)
}
function Format-StatePct([int]$Milli) {
'@
    if (-not $source.Contains($psClock) -or -not $source.Contains($psDumpMarker) -or -not $source.Contains($psMathMarker)) { throw 'PowerShell state test marker missing' }
    $statePsSource = $source.Replace($psClock, $psClockHook.TrimEnd()).Replace($psDumpMarker, $psDumpHook.TrimEnd()).Replace($psMathMarker, $psMathHook.TrimEnd())
    Write-Utf8 $script:StateScript $statePsSource

    $script:FloatScript = Join-Path $TempRoot 'statusline-float-test.ps1'
    $floatBeforeParentMarker = '        # WIN03_TEST_BEFORE_PARENT_CREATE'
    $floatAfterParentMarker = '    # WIN03_TEST_AFTER_PARENT_CREATE'
    $floatAfterTempMarker = '                # WIN03_TEST_AFTER_TEMP_CLOSE'
    $floatBeforeParentHook = @'
        if (-not [string]::IsNullOrEmpty([string]$env:CORALLINE_TEST_FLOAT_BEFORE_PARENT)) {
            [IO.File]::WriteAllBytes(([string]$env:CORALLINE_TEST_FLOAT_BEFORE_PARENT + '.' + [string]$PID + '.ready'), [byte[]]@())
            while (-not [IO.File]::Exists([string]$env:CORALLINE_TEST_FLOAT_BEFORE_PARENT)) { Start-Sleep -Milliseconds 10 }
        }
'@
    $floatAfterParentHook = @'
    if (-not [string]::IsNullOrEmpty([string]$env:CORALLINE_TEST_FLOAT_AFTER_PARENT)) {
        [IO.File]::WriteAllBytes(([string]$env:CORALLINE_TEST_FLOAT_AFTER_PARENT + '.' + [string]$PID + '.ready'), [byte[]]@())
        while (-not [IO.File]::Exists([string]$env:CORALLINE_TEST_FLOAT_AFTER_PARENT)) { Start-Sleep -Milliseconds 10 }
    }
'@
    $floatAfterTempHook = @'
                if (-not [string]::IsNullOrEmpty([string]$env:CORALLINE_TEST_FLOAT_AFTER_TEMP)) {
                    [IO.File]::WriteAllBytes(([string]$env:CORALLINE_TEST_FLOAT_AFTER_TEMP + '.' + [string]$PID + '.ready'), [byte[]]@())
                    while (-not [IO.File]::Exists([string]$env:CORALLINE_TEST_FLOAT_AFTER_TEMP)) { Start-Sleep -Milliseconds 10 }
                }
'@
    if (-not $source.Contains($floatBeforeParentMarker) -or -not $source.Contains($floatAfterParentMarker) -or -not $source.Contains($floatAfterTempMarker)) { throw 'WIN-03 float barrier marker missing' }
    $floatSource = $source.Replace($floatBeforeParentMarker, $floatBeforeParentHook.TrimEnd()).Replace($floatAfterParentMarker, $floatAfterParentHook.TrimEnd()).Replace($floatAfterTempMarker, $floatAfterTempHook.TrimEnd())
    Write-Utf8 $script:FloatScript $floatSource

    $script:StateBashScript = Join-Path $TempRoot 'statusline-state-test.sh'
    $bashClock = 'printf -v NOW ''%(%s)T'' -1 2>/dev/null || NOW=$(date +%s)'
    $bashClockHook = @'
printf -v NOW '%(%s)T' -1 2>/dev/null || NOW=$(date +%s)
case "${CORALLINE_TEST_NOW:-}" in
  (0|[1-9][0-9]*)
    if [ "${#CORALLINE_TEST_NOW}" -le 12 ]; then
      _TEST_NOW=$(( 10#$CORALLINE_TEST_NOW ))
      [ "$_TEST_NOW" -le 253402300799 ] && NOW=$_TEST_NOW
    fi ;;
esac
'@
    $bashDumpMarker = '  case "$_SEG_SCAN" in (*" burn "*) burn_estimate ;; esac'
    $bashDumpHook = @'
  case "$_SEG_SCAN" in (*" burn "*) burn_estimate ;; esac
  if [ -n "${CORALLINE_TEST_STATE_DUMP:-}" ]; then
    printf '%s\n' "BurnState=$_BURN_STATE BurnLabel=$_BURN_LABEL BurnEta=$_BURN_ETA BurnRate=$_BURN_RATE BurnTtr=$_BURN_TTR FiveState=$_B5_STATE FiveEta=$_B5_ETA FiveRate=$_B5_RATE FiveTtr=$_B5_TTR SevenEta=$_B7_ETA SevenRate=$_B7_RATE SevenTtr=$_B7_TTR Limit5Valid=$_STATE_RL5_VALID Limit5Reset=$_STATE_RL5_RST Limit5Pct=$_STATE_RL5_PCT Limit7Valid=$_STATE_RL7_VALID Limit7Reset=$_STATE_RL7_RST Limit7Pct=$_STATE_RL7_PCT" > "$CORALLINE_TEST_STATE_DUMP"
  fi
'@
    if (-not $bashSource.Contains($bashClock) -or -not $bashSource.Contains($bashDumpMarker)) { throw 'Bash state test marker missing' }
    $stateBashSource = $bashSource.Replace($bashClock, $bashClockHook.TrimEnd()).Replace($bashDumpMarker, $bashDumpHook.TrimEnd())
    Write-Utf8 $script:StateBashScript $stateBashSource

    Check 'static source has no production deterministic-clock hook' (-not $source.Contains('CORALLINE_TEST_NOW') -and -not $bashSource.Contains('CORALLINE_TEST_NOW'))
    Check 'static source has no mojibake double question token' (-not $source.Contains(('?' + '?')))
    Check 'static source has no dangling handoff reference' (-not $source.Contains('handoff/'))
    Check 'static source forbids Invoke-Expression' (-not $source.Contains('Invoke-Expression'))
    Check 'static source forbids dynamic ScriptBlock creation' (-not $source.Contains('ScriptBlock]::Create'))
    Check 'literal subagent route precedes stdin open' ($source.IndexOf("-ceq '--subagent'") -ge 0 -and $source.IndexOf("-ceq '--subagent'") -lt $source.IndexOf('OpenStandardInput'))
    Check 'subagent byte cap precedes strict UTF-8 decode' ($source.IndexOf('$inputCap = 4194304') -ge 0 -and $source.IndexOf('$inputCap = 4194304') -lt $source.IndexOf('$StrictUtf8.GetString($inputBytes'))
    Check 'subagent exits before main JSON parse and state paths' ($source.IndexOf('Invoke-SubagentMode $rawInput') -lt $source.IndexOf('ConvertFrom-Json -ErrorAction Stop') -and $source.IndexOf('Invoke-SubagentMode $rawInput') -lt $source.IndexOf('$AllStatePaths'))
    Check 'subagent row and serialized-line caps are explicit' ($source.Contains('GetByteCount($content) -gt 65536') -and $source.Contains('GetByteCount($line) + 1) -gt 524288'))
    Check 'UNC lexical rejection precedes canonicalization' ($source.IndexOf("StartsWith('\\'") -ge 0 -and $source.IndexOf("StartsWith('\\'") -lt $source.IndexOf('GetFullPath($p)'))
    Check 'reparse validation precedes config read' ($source.IndexOf('Test-SafeRegularFile $Path') -lt $source.IndexOf('Read-StrictUtf8File $Path'))
    Check 'Bash oracle main extraction contains central scrub' ($bashSource.Contains('] | map(scrub) | join('))

    $expectedRegistry = @('burn','clock','cost','ctx','dir','duration','effort','git','limit5h','limit7d','lines','model','node','project','python','stash','style')
    $builderBlock = [regex]::Match($source, '(?s)\$SegmentBuilders = \[ordered\]@\{(.*?)\n\}').Groups[1].Value
    $actualRegistry = @([regex]::Matches($builderBlock, '(?m)^    ([A-Za-z0-9]+) =') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    Check 'closed PowerShell registry equals WIN-02 inventory' (($actualRegistry -join ' ') -eq (($expectedRegistry | Sort-Object) -join ' '))
    $bashSegments = @([regex]::Matches($bashSource, '(?m)^seg_([A-Za-z0-9_]+)\(\)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '_' -and $_ -ne 'len' -and $_ -ne 'limit' } | Sort-Object -Unique)
    Check 'Bash public registry equals WIN-02 inventory' (($bashSegments -join ' ') -eq (($expectedRegistry | Sort-Object) -join ' '))

    $script:BashExe = $env:CORALLINE_TEST_BASH
    if ([string]::IsNullOrEmpty($script:BashExe)) { $script:BashExe = 'C:\Program Files\Git\bin\bash.exe' }
    Check 'Git Bash oracle executable exists' ([System.IO.File]::Exists($script:BashExe))
    if (-not [System.IO.File]::Exists($script:BashExe)) { throw 'Git Bash oracle is required for WIN-01 tests' }
    $bashProbe = Invoke-CapturedProcess $script:BashExe '--noprofile --norc -lc "command -v jq >/dev/null && printf ready"' '' @{} $Repo 5000
    Check 'Git Bash jq oracle available' ($bashProbe.ExitCode -eq 0 -and $bashProbe.Stdout -eq 'ready' -and $bashProbe.StderrBytes.Length -eq 0)
    if ($bashProbe.ExitCode -ne 0) { throw 'Git Bash jq oracle unavailable' }

    $script:GitExe = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $gitRoot = Join-Path $TempRoot 'fixture-repo'
    [void][System.IO.Directory]::CreateDirectory($gitRoot)
    [System.IO.File]::WriteAllText((Join-Path $gitRoot 'a.txt'), "one`n", $Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $gitRoot '.nvmrc'), "v20.11.1`n", $Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $gitRoot '.python-version'), "3.12.2`n", $Utf8NoBom)
    [void](Run-Git $gitRoot 'init -q')
    [void](Run-Git $gitRoot 'checkout -q -b main')
    [void](Run-Git $gitRoot 'config user.email test@example.com')
    [void](Run-Git $gitRoot 'config user.name test')
    [void](Run-Git $gitRoot 'add a.txt .nvmrc .python-version')
    [void](Run-Git $gitRoot 'commit -q -m init')
    [System.IO.File]::AppendAllText((Join-Path $gitRoot 'a.txt'), "stash`n", $Utf8NoBom)
    [void](Run-Git $gitRoot 'stash push -q -m fixture')
    $cwd = Forward-Path $gitRoot
    $repoLeaf = [System.IO.Path]::GetFileName($gitRoot)
    $basePayload = New-Payload $cwd

    $compatPayload = Json $basePayload
    $compatCases = @(
        [pscustomobject]@{ Name='flags absent'; Lines=@('VL_SEGMENTS=ctx\ cost','VL_CLOCK=off','VL_NOCOLOR=1','VL_COST_DECIMALS=3') },
        [pscustomobject]@{ Name='flags explicit zero'; Lines=@('VL_SEGMENTS=ctx\ cost','VL_CLOCK=off','VL_NOCOLOR=1','VL_COST_DECIMALS=3','VL_CTX_ALWAYS_SHOW=0','VL_COST_ALWAYS_SHOW=0') }
    )
    $compatPs = @{}
    $compatBash = @{}
    foreach ($compat in $compatCases) {
        $config = New-Config ('ctx-cost-compat-' + ($compat.Name -replace ' ', '-')) $compat.Lines
        $compatPs[$compat.Name] = Invoke-Statusline $compatPayload $config @{} '' 5000
        $compatBash[$compat.Name] = Invoke-BashStatusline $compatPayload $config @{}
        Check-Run ('candidate PowerShell ' + $compat.Name) ($compatPs[$compat.Name])
        Check-Run ('candidate Bash ' + $compat.Name) ($compatBash[$compat.Name])
        Check-Exact ('candidate ctx/cost differential ' + $compat.Name) ($compatPs[$compat.Name]) ($compatBash[$compat.Name])
    }
    Check-Exact 'PowerShell absent and explicit-zero flags are byte exact' ($compatPs['flags absent']) ($compatPs['flags explicit zero'])
    Check-Exact 'Bash absent and explicit-zero flags are byte exact' ($compatBash['flags absent']) ($compatBash['flags explicit zero'])

    $gitParityConfig = New-Config 'git-edge-parity' @('VL_SEGMENTS=git\ project','VL_CLOCK=off')
    $unbornRoot = Join-Path $TempRoot 'empty-repo'
    [void][System.IO.Directory]::CreateDirectory($unbornRoot)
    [void](Run-Git $unbornRoot 'init -q')
    [void](Run-Git $unbornRoot 'checkout -q -b main')
    $unbornPayload = New-Payload (Forward-Path $unbornRoot)
    $unbornPs = Invoke-Statusline (Json $unbornPayload) $gitParityConfig @{} '' 5000
    $unbornBash = Invoke-BashStatusline (Json $unbornPayload) $gitParityConfig @{}
    Check-Run 'PowerShell unborn Git repository' $unbornPs
    Check-Run 'Bash unborn Git repository' $unbornBash
    Check-Exact 'unborn Git repository differential is byte exact' $unbornPs $unbornBash
    Check 'unborn Git renders branch and project' ((Plain $unbornPs.Stdout).Contains('main') -and (Plain $unbornPs.Stdout).Contains('empty-repo'))

    $detachedRoot = Join-Path $TempRoot 'detached-repo'
    [void][System.IO.Directory]::CreateDirectory($detachedRoot)
    Write-Utf8 (Join-Path $detachedRoot 'tracked.txt') "tracked`n"
    [void](Run-Git $detachedRoot 'init -q')
    [void](Run-Git $detachedRoot 'checkout -q -b main')
    [void](Run-Git $detachedRoot 'config user.email test@example.com')
    [void](Run-Git $detachedRoot 'config user.name test')
    [void](Run-Git $detachedRoot 'add tracked.txt')
    [void](Run-Git $detachedRoot 'commit -q -m init')
    $detachedShort = (Run-Git $detachedRoot 'rev-parse --short=7 HEAD').Stdout.Trim()
    [void](Run-Git $detachedRoot 'checkout -q --detach')
    $detachedPayload = New-Payload (Forward-Path $detachedRoot)
    $detachedPs = Invoke-Statusline (Json $detachedPayload) $gitParityConfig @{} '' 5000
    $detachedBash = Invoke-BashStatusline (Json $detachedPayload) $gitParityConfig @{}
    Check-Run 'PowerShell detached Git repository' $detachedPs
    Check-Run 'Bash detached Git repository' $detachedBash
    Check-Exact 'detached Git repository differential is byte exact' $detachedPs $detachedBash
    Check 'detached Git keeps short oid and project' ((Plain $detachedPs.Stdout).Contains($detachedShort) -and (Plain $detachedPs.Stdout).Contains('detached-repo'))

    $unicodeLeaf = (Glyph 0x96EA) + 'repo'
    $unicodeBranch = (Glyph 0x529F) + (Glyph 0x80FD)
    $unicodeRoot = Join-Path $TempRoot $unicodeLeaf
    [void][System.IO.Directory]::CreateDirectory($unicodeRoot)
    Write-Utf8 (Join-Path $unicodeRoot 'tracked.txt') "tracked`n"
    [void](Run-Git $unicodeRoot 'init -q')
    [void](Run-Git $unicodeRoot ('checkout -q -b ' + $unicodeBranch))
    [void](Run-Git $unicodeRoot 'config user.email test@example.com')
    [void](Run-Git $unicodeRoot 'config user.name test')
    [void](Run-Git $unicodeRoot 'add tracked.txt')
    [void](Run-Git $unicodeRoot 'commit -q -m init')
    $unicodePayload = New-Payload (Forward-Path $unicodeRoot)
    $unicodeCommand = '[Console]::OutputEncoding=[Text.Encoding]::GetEncoding(437); & ''' + $Script + ''''
    $unicodeArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + $unicodeCommand.Replace('"','\"') + '"'
    $unicodePs = Invoke-CapturedProcess $PowerShellExe $unicodeArgs (Json $unicodePayload) (Runtime-Environment $gitParityConfig @{}) $Repo 5000
    $unicodeBash = Invoke-BashStatusline (Json $unicodePayload) $gitParityConfig @{}
    Check-Run 'PowerShell codepage 437 Unicode Git repository' $unicodePs
    Check-Run 'Bash Unicode Git repository' $unicodeBash
    Check-Exact 'Unicode Git repository differential is byte exact' $unicodePs $unicodeBash
    Check 'Unicode Git keeps project and branch text' ((Plain $unicodePs.Stdout).Contains($unicodeLeaf) -and (Plain $unicodePs.Stdout).Contains($unicodeBranch))

    $scalar = Glyph 0x1F600
    $scalarRoot = Join-Path $TempRoot ($scalar + 'repo')
    [void][System.IO.Directory]::CreateDirectory($scalarRoot)
    Write-Utf8 (Join-Path $scalarRoot 'tracked.txt') "tracked`n"
    [void](Run-Git $scalarRoot 'init -q')
    [void](Run-Git $scalarRoot ('checkout -q -b ' + $scalar + 'branch'))
    [void](Run-Git $scalarRoot 'config user.email test@example.com')
    [void](Run-Git $scalarRoot 'config user.name test')
    [void](Run-Git $scalarRoot 'add tracked.txt')
    [void](Run-Git $scalarRoot 'commit -q -m init')
    $scalarPayload = New-Payload (Forward-Path $scalarRoot)
    $scalarOneConfig = New-Config 'unicode-scalar-max-one' @('VL_SEGMENTS=project\ git','VL_CLOCK=off','VL_NAME_MAX=1')
    $scalarOnePs = Invoke-Statusline (Json $scalarPayload) $scalarOneConfig @{} '' 5000
    Check-Run 'PowerShell Unicode scalar max one' $scalarOnePs
    Check 'Unicode scalar max one preserves the complete scalar' ((Plain $scalarOnePs.Stdout).Contains($scalar))
    Check 'Unicode scalar max one emits no replacement character' (-not $scalarOnePs.Stdout.Contains([char]0xFFFD))

    [void](Run-Git $scalarRoot ('branch -m ' + 'ABCD' + $scalar + 'F'))
    $scalarTailConfig = New-Config 'unicode-scalar-tail' @('VL_SEGMENTS=git','VL_CLOCK=off','VL_NAME_MAX=4')
    $scalarTailPs = Invoke-Statusline (Json $scalarPayload) $scalarTailConfig @{} '' 5000
    Check-Run 'PowerShell Unicode scalar tail boundary' $scalarTailPs
    Check 'Unicode scalar tail keeps the complete suffix' ((Plain $scalarTailPs.Stdout).Contains('A' + (Glyph 0x2026) + $scalar + 'F'))
    Check 'Unicode scalar tail emits no replacement character' (-not $scalarTailPs.Stdout.Contains([char]0xFFFD))

    $script:QuoteHelper = Join-Path $TempRoot 'configure-quote.sh'
    Write-Utf8 $script:QuoteHelper @'
#!/usr/bin/env bash
eval "$(sed -n '/^shell_quote()/,/^}/p' "$CORALLINE_CONFIGURE")"
shell_quote "$CORALLINE_Q_VALUE"
'@

    $subTask = [ordered]@{
        id='row-1'
        name='Builder'
        label='Compile tests'
        description='fallback detail'
        type='local_agent'
        status='running'
        model='claude-haiku-4-5-20251001'
        contextWindowSize='200000'
        tokenCount='50000'
    }
    $subPayload = [ordered]@{ transcript_path=''; tasks=@($subTask) }
    $subJson = Json $subPayload
    $subDefault = Invoke-Subagent $subJson '' @{}
    $subDefaultBash = Invoke-BashSubagent $subJson '' @{}
    Check-Run 'WIN-PS1 subagent default' $subDefault
    Check-Run 'WIN-PS1 Bash subagent default oracle' $subDefaultBash
    Check-Exact 'WIN-PS1 default subagent row is byte exact to Bash' $subDefault $subDefaultBash
    $subRows = @(Get-SubagentRows $subDefault)
    Check 'WIN-PS1 compact row parses with exact id/content members' ($subRows.Count -eq 1 -and $subRows[0].id -ceq 'row-1' -and $subRows[0].content.Contains('Builder') -and $subRows[0].content.Contains('Haiku 4.5') -and $subRows[0].content.Contains('25%'))
    Check 'WIN-PS1 row stdout is LF UTF-8 without BOM' ($subDefault.StdoutBytes.Length -gt 0 -and $subDefault.StdoutBytes[$subDefault.StdoutBytes.Length - 1] -eq 10 -and -not ($subDefault.StdoutBytes[0] -eq 0xEF -and $subDefault.StdoutBytes[1] -eq 0xBB -and $subDefault.StdoutBytes[2] -eq 0xBF))

    foreach ($theme in @(Get-ChildItem -LiteralPath (Join-Path $Repo 'themes') -Filter '*.conf' -File | Sort-Object Name)) {
        $themeConfig = New-Config ('sub-theme-' + $theme.BaseName) @(
            ('. ' + (Quote-FromConfigure (Forward-Path $theme.FullName))),
            ('VL_SUB_SEGMENTS=' + (Quote-FromConfigure 'name model ctx'))
        )
        $themePs = Invoke-Subagent $subJson $themeConfig @{}
        $themeBash = Invoke-BashSubagent $subJson $themeConfig @{}
        Check-Run ('WIN-PS1 theme ' + $theme.BaseName) $themePs
        Check-Exact ('WIN-PS1 theme parity ' + $theme.BaseName) $themePs $themeBash
    }

    $themePath = Forward-Path (Join-Path $Repo 'themes\claude-coral.conf')
    $subStyleCases = @(
        [pscustomobject]@{ Name='ascii'; Lines=@('VL_ASCII=1') },
        [pscustomobject]@{ Name='classic'; Lines=@('VL_STYLE=classic') },
        [pscustomobject]@{ Name='bare-lean'; Lines=@('VL_STYLE=lean') },
        [pscustomobject]@{ Name='fingerprint-retint'; Lines=@('VL_FG_OK=0,0,0') },
        [pscustomobject]@{ Name='explicit-empty-name'; Lines=@("VL_BG_SUB_NAME=''") },
        [pscustomobject]@{ Name='explicit-empty-ok'; Lines=@("VL_FG_SUB_OK=''"; 'VL_STYLE=classic') },
        [pscustomobject]@{ Name='custom-order'; Lines=@(('VL_SUB_SEGMENTS=' + (Quote-FromConfigure 'ctx name model'))) }
    )
    foreach ($styleCase in $subStyleCases) {
        $lines = @(('. ' + (Quote-FromConfigure $themePath))) + $styleCase.Lines
        $config = New-Config ('sub-style-' + $styleCase.Name) $lines
        $psRun = Invoke-Subagent $subJson $config @{}
        $bashRun = Invoke-BashSubagent $subJson $config @{}
        Check-Run ('WIN-PS1 style gate ' + $styleCase.Name) $psRun
        Check-Exact ('WIN-PS1 style gate parity ' + $styleCase.Name) $psRun $bashRun
    }

    $nameOnlyConfig = New-Config 'sub-name-only' @(('VL_SUB_SEGMENTS=' + (Quote-FromConfigure 'name')))
    $oldDoc = '{"tasks":[{"id":"old","name":"old"}]}'
    $newDoc = '{"tasks":[{"id":"new","name":"new"}]}'
    foreach ($validStream in @($oldDoc + $newDoc, $oldDoc + " `t`r`n" + $newDoc)) {
        $run = Invoke-Subagent $validStream $nameOnlyConfig @{}
        Check-Run 'WIN-PS1 valid concatenated stream' $run
        $rows = @(Get-SubagentRows $run)
        Check 'WIN-PS1 renders only the last complete JSON value' ($rows.Count -eq 1 -and $rows[0].id -ceq 'new')
    }
    $invalidStreams = @(
        'x' + $newDoc,
        $oldDoc + 'x' + $newDoc,
        $newDoc + 'x',
        '{"tasks":[',
        $oldDoc + [char]12 + $newDoc,
        $oldDoc + [char]11 + $newDoc,
        $oldDoc + [char]0 + $newDoc,
        '{"tasks":[],"tasks":[]}',
        '{"tasks":[],"Tasks":[]}',
        '{"tasks":[],"\u0074asks":[]}',
        '{"tasks":[],"nested":{"id":1,"ID":2}}',
        '{"tasks":[{"id":"x","id":"y"}]}'
    )
    $invalidIndex = 0
    foreach ($invalidStream in $invalidStreams) {
        $run = Invoke-Subagent $invalidStream $nameOnlyConfig @{}
        Check-Run ('WIN-PS1 rejected stream ' + $invalidIndex) $run
        Check ('WIN-PS1 rejected stream is silent ' + $invalidIndex) ($run.StdoutBytes.Length -eq 0)
        $invalidIndex++
    }
    foreach ($noTasks in @('{"Tasks":[{"id":"x","name":"x"}]}','{"tasks":{}}','{"tasks":null}','[]','true')) {
        $run = Invoke-Subagent $noTasks $nameOnlyConfig @{}
        Check-Run 'WIN-PS1 exact tasks array gate' $run
        Check 'WIN-PS1 non-array or case-variant tasks is silent' ($run.StdoutBytes.Length -eq 0)
    }
    $nodeCap = Invoke-Subagent (New-SubagentNodePayload 32762) $nameOnlyConfig @{}
    Check-Run 'WIN-PS1 32768-node boundary' $nodeCap
    Check 'WIN-PS1 32768 nodes retain the valid task' (@(Get-SubagentRows $nodeCap).Count -eq 1)
    $nodeOver = Invoke-Subagent (New-SubagentNodePayload 32763) $nameOnlyConfig @{}
    Check-Run 'WIN-PS1 32769-node boundary' $nodeOver
    Check 'WIN-PS1 32769 nodes reject the entire input' ($nodeOver.StdoutBytes.Length -eq 0)
    $depthCap = Invoke-Subagent (New-SubagentDepthPayload 127) $nameOnlyConfig @{}
    Check-Run 'WIN-PS1 128-level nesting boundary' $depthCap
    Check 'WIN-PS1 128-level nesting retains the valid task' (@(Get-SubagentRows $depthCap).Count -eq 1)
    $depthOver = Invoke-Subagent (New-SubagentDepthPayload 128) $nameOnlyConfig @{}
    Check-Run 'WIN-PS1 129-level nesting boundary' $depthOver
    Check 'WIN-PS1 129-level nesting rejects the entire input' ($depthOver.StdoutBytes.Length -eq 0)
    $mixedTasks = Invoke-Subagent '{"tasks":[null,1,[],{"id":"kept","name":"kept"},{}]}' $nameOnlyConfig @{}
    Check-Run 'WIN-PS1 skips non-object tasks' $mixedTasks
    Check 'WIN-PS1 non-object tasks leave the valid row' (@(Get-SubagentRows $mixedTasks).Count -eq 1)

    $taskBuilder = New-Object System.Text.StringBuilder
    [void]$taskBuilder.Append('{"tasks":[')
    for ($i=0; $i -lt 1024; $i++) {
        if ($i -gt 0) { [void]$taskBuilder.Append(',') }
        [void]$taskBuilder.Append('{"id":"t')
        [void]$taskBuilder.Append($i)
        [void]$taskBuilder.Append('","name":"n"}')
    }
    [void]$taskBuilder.Append(']}')
    $taskCap = Invoke-Subagent $taskBuilder.ToString() $nameOnlyConfig @{}
    Check-Run 'WIN-PS1 1024-task boundary' $taskCap
    Check 'WIN-PS1 1024 tasks render 1024 rows' (@(Get-SubagentRows $taskCap).Count -eq 1024)
    [void]$taskBuilder.Remove($taskBuilder.Length - 2, 2)
    [void]$taskBuilder.Append(',{"id":"over","name":"over"}]}')
    $taskOver = Invoke-Subagent $taskBuilder.ToString() $nameOnlyConfig @{}
    Check-Run 'WIN-PS1 1025-task boundary' $taskOver
    Check 'WIN-PS1 1025 tasks reject the entire input' ($taskOver.StdoutBytes.Length -eq 0)

    foreach ($fieldName in @('id','name','label','description','type','status','startTime','model','contextWindowSize','tokenCount')) {
        foreach ($composite in @('{}','[]')) {
            if ($fieldName -ceq 'id') { $raw = '{"tasks":[{"id":' + $composite + ',"name":"fallback"}]}' }
            elseif ($fieldName -ceq 'name') { $raw = '{"tasks":[{"id":"scalar-test","name":' + $composite + ',"type":"fallback"}]}' }
            else { $raw = '{"tasks":[{"id":"scalar-test","name":"fallback","' + $fieldName + '":' + $composite + '}]}' }
            $run = Invoke-Subagent $raw $nameOnlyConfig @{}
            Check-Run ('WIN-PS1 composite field ' + $fieldName) $run
            if ($fieldName -ceq 'id') { Check ('WIN-PS1 composite id suppresses row ' + $composite) ($run.StdoutBytes.Length -eq 0) }
            else { Check ('WIN-PS1 composite field degrades empty ' + $fieldName + $composite) (@(Get-SubagentRows $run).Count -eq 1) }
        }
    }
    foreach ($compositeTranscript in @('{"transcript_path":{},"tasks":[{"id":"x","name":"x"}]}','{"transcript_path":[],"tasks":[{"id":"x","name":"x"}]}')) {
        $run = Invoke-Subagent $compositeTranscript $nameOnlyConfig @{}
        Check-Run 'WIN-PS1 composite transcript path' $run
        Check 'WIN-PS1 composite transcript path only disables sidecar' (@(Get-SubagentRows $run).Count -eq 1)
    }
    foreach ($scalarCase in @(
        [pscustomobject]@{ Raw='{"tasks":[{"id":7,"name":12}]}' ; Id='7'; Label='12' },
        [pscustomobject]@{ Raw='{"tasks":[{"id":true,"name":false}]}' ; Id='true'; Label='false' },
        [pscustomobject]@{ Raw='{"tasks":[{"id":"null-name","name":null,"type":"fallback"}]}' ; Id='null-name'; Label='fallback' }
    )) {
        $run = Invoke-Subagent $scalarCase.Raw $nameOnlyConfig @{}
        Check-Run 'WIN-PS1 invariant scalar conversion' $run
        $rows = @(Get-SubagentRows $run)
        Check 'WIN-PS1 invariant scalar id and label' ($rows.Count -eq 1 -and $rows[0].id -ceq $scalarCase.Id -and (Plain $rows[0].content).Contains($scalarCase.Label))
    }
    $numberCanonicalRaw = '{"tasks":[{"id":1e999,"name":1e999},{"id":1e-999,"name":1e-999},{"id":123e999,"name":123e999},{"id":1.2300e999,"name":1.2300e999},{"id":1e1,"name":1e1},{"id":1.20e2,"name":1.20e2},{"id":0e-7,"name":0e-7},{"id":999999999999999999999999,"name":999999999999999999999999},{"id":12e999999998,"name":12e999999998},{"id":12e999999999,"name":12e999999999},{"id":-1e1000000000,"name":-1e1000000000},{"id":0e1000000000,"name":0e1000000000},{"id":1e-1147483646,"name":1e-1147483646},{"id":4e-1147483647,"name":4e-1147483647},{"id":5e-1147483647,"name":5e-1147483647},{"id":-5e-1147483647,"name":-5e-1147483647},{"id":1.5e-1147483646,"name":1.5e-1147483646},{"id":9.5e-1147483646,"name":9.5e-1147483646},{"id":0e-2000000000,"name":0e-2000000000}]}'
    $numberCanonicalPs = Invoke-Subagent $numberCanonicalRaw $nameOnlyConfig @{}
    $numberCanonicalBash = Invoke-BashSubagent $numberCanonicalRaw $nameOnlyConfig @{}
    Check-Run 'WIN-PS1 exact decimal canonicalization' $numberCanonicalPs
    Check-Run 'WIN-PS1 Bash exact decimal canonicalization oracle' $numberCanonicalBash
    Check-Exact 'WIN-PS1 exact decimal canonicalization parity' $numberCanonicalPs $numberCanonicalBash
    $numberCanonicalRows = @(Get-SubagentRows $numberCanonicalPs)
    $numberCanonicalExpected = @('1E+999','1E-999','1.23E+1001','1.2300E+999','1E+1','120','0E-7','999999999999999999999999','1.2E+999999999','1.7976931348623157e+308','-1.7976931348623157e+308','0E+999999999','1E-1147483646','0E-1147483646','1E-1147483646','-1E-1147483646','2E-1147483646','1.0E-1147483645','0E-1147483646')
    Check 'WIN-PS1 exact decimal canonicalization row count' ($numberCanonicalRows.Count -eq $numberCanonicalExpected.Count)
    for ($i=0; $i -lt $numberCanonicalExpected.Count -and $i -lt $numberCanonicalRows.Count; $i++) {
        Check ('WIN-PS1 exact decimal canonicalization ' + $i) ($numberCanonicalRows[$i].id -ceq $numberCanonicalExpected[$i] -and (Plain $numberCanonicalRows[$i].content).Contains($numberCanonicalExpected[$i]))
    }

    $escapedRaw = '{"tasks":[{"id":"quote\"\\id","name":"quote\" slash\\ esc\u001b[2J","status":true}]}'
    $escapedRun = Invoke-Subagent $escapedRaw $nameOnlyConfig @{}
    Check-Run 'WIN-PS1 quote backslash and ESC scrub' $escapedRun
    $escapedRows = @(Get-SubagentRows $escapedRun)
    Check 'WIN-PS1 JSON quoting round-trips id and label' ($escapedRows.Count -eq 1 -and $escapedRows[0].id -ceq "quote`"\id" -and (Plain $escapedRows[0].content).Contains("quote`" slash\ esc[2J"))
    Check 'WIN-PS1 untrusted ESC cannot survive as CSI' (-not $escapedRows[0].content.Contains(([string][char]27 + '[2J')))

    $asciiExact = 'a' * 16384
    $asciiOver = $asciiExact + 'b'
    $multiExact = ((Glyph 0x96EA) * 5461) + 'a'
    $multiOver = $multiExact + 'b'
    foreach ($boundary in @(
        [pscustomobject]@{ Name='name-ascii'; Value=$asciiExact; Accepted=$true; Field='name' },
        [pscustomobject]@{ Name='name-ascii-over'; Value=$asciiOver; Accepted=$false; Field='name' },
        [pscustomobject]@{ Name='name-multibyte'; Value=$multiExact; Accepted=$true; Field='name' },
        [pscustomobject]@{ Name='name-multibyte-over'; Value=$multiOver; Accepted=$false; Field='name' },
        [pscustomobject]@{ Name='id-ascii'; Value=$asciiExact; Accepted=$true; Field='id' },
        [pscustomobject]@{ Name='id-ascii-over'; Value=$asciiOver; Accepted=$false; Field='id' },
        [pscustomobject]@{ Name='id-multibyte'; Value=$multiExact; Accepted=$true; Field='id' },
        [pscustomobject]@{ Name='id-multibyte-over'; Value=$multiOver; Accepted=$false; Field='id' }
    )) {
        if ($boundary.Field -ceq 'id') { $payload = [ordered]@{ tasks=@([ordered]@{ id=$boundary.Value; name='n' }) } }
        else { $payload = [ordered]@{ tasks=@([ordered]@{ id='field-bound'; name=$boundary.Value }) } }
        $run = Invoke-Subagent (Json $payload) $nameOnlyConfig @{}
        Check-Run ('WIN-PS1 field byte boundary ' + $boundary.Name) $run
        Check ('WIN-PS1 field boundary acceptance ' + $boundary.Name) ((@((Get-SubagentRows $run)).Count -eq 1) -eq $boundary.Accepted)
    }

    $ctxOnlyConfig = New-Config 'sub-ctx-only' @(('VL_SUB_SEGMENTS=' + (Quote-FromConfigure 'ctx')))
    foreach ($vector in @(
        [pscustomobject]@{ Name='floor'; Tok='1'; Win='3'; Show=$true; Needle='33%' },
        [pscustomobject]@{ Name='large-exact-floor'; Tok='299999999999998'; Win='9999999999999934'; Show=$true; Needle='2%' },
        [pscustomobject]@{ Name='clamp'; Tok='9999999999999999'; Win='1'; Show=$true; Needle='100%' },
        [pscustomobject]@{ Name='large-token-abbreviation'; Tok='9999999999999999'; Win='0'; Show=$true; Needle='9999999999.9M' },
        [pscustomobject]@{ Name='below-million'; Tok='999999'; Win='0'; Show=$true; Needle='999.9k' },
        [pscustomobject]@{ Name='at-million'; Tok='1000000'; Win='0'; Show=$true; Needle='1.0M' },
        [pscustomobject]@{ Name='zero-window'; Tok='1000'; Win='0'; Show=$true; Needle='1.0k' },
        [pscustomobject]@{ Name='invalid-window'; Tok='1000'; Win='10000000000000000'; Show=$true; Needle='1.0k' },
        [pscustomobject]@{ Name='invalid-token'; Tok='10000000000000000'; Win='1'; Show=$false; Needle='' },
        [pscustomobject]@{ Name='signed-token'; Tok='-1'; Win='3'; Show=$false; Needle='' }
    )) {
        $payload = [ordered]@{ tasks=@([ordered]@{ id=$vector.Name; tokenCount=$vector.Tok; contextWindowSize=$vector.Win }) }
        $run = Invoke-Subagent (Json $payload) $ctxOnlyConfig @{}
        Check-Run ('WIN-PS1 ctx numeric ' + $vector.Name) $run
        $shown = @(Get-SubagentRows $run)
        Check ('WIN-PS1 ctx numeric semantics ' + $vector.Name) (($shown.Count -eq 1) -eq $vector.Show)
        if ($vector.Show) { Check ('WIN-PS1 ctx text ' + $vector.Name) ((Plain $shown[0].content).Contains($vector.Needle)) }
    }
    $numericCtx = Invoke-Subagent '{"tasks":[{"id":"numeric","tokenCount":1000,"contextWindowSize":2000}]}' $ctxOnlyConfig @{}
    Check-Run 'WIN-PS1 numeric JSON context scalars' $numericCtx
    Check 'WIN-PS1 numeric JSON context scalars use invariant digits' ((Plain (@(Get-SubagentRows $numericCtx)[0].content)).Contains('50%'))

    $elapsedOnlyConfig = New-Config 'sub-elapsed-only' @(('VL_SUB_SEGMENTS=' + (Quote-FromConfigure 'elapsed')))
    $epochNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $fractionAtFieldCap = '1970-01-01T00:00:00.' + (('0' * 16363) -join '') + 'Z'
    $fractionOverFieldCap = '1970-01-01T00:00:00.' + (('0' * 16364) -join '') + 'Z'
    $elapsedVectors = @(
        [pscustomobject]@{ Name='seconds'; Value=[string]($epochNow - 65); Show=$true },
        [pscustomobject]@{ Name='milliseconds'; Value=[string](($epochNow - 65) * 1000); Show=$true },
        [pscustomobject]@{ Name='iso'; Value=[DateTimeOffset]::FromUnixTimeSeconds($epochNow - 65).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $Invariant); Show=$true },
        [pscustomobject]@{ Name='iso-year-zero'; Value='0000-01-01T00:00:00Z'; Show=$true },
        [pscustomobject]@{ Name='iso-year-zero-leap-day'; Value='0000-02-29T00:00:00Z'; Show=$true },
        [pscustomobject]@{ Name='iso-year-zero-bad-date'; Value='0000-02-30T00:00:00Z'; Show=$false },
        [pscustomobject]@{ Name='iso-before-epoch'; Value='1969-12-31T23:59:59Z'; Show=$true },
        [pscustomobject]@{ Name='iso-at-epoch'; Value='1970-01-01T00:00:00Z'; Show=$true },
        [pscustomobject]@{ Name='iso-fraction-pre-epoch'; Value='1969-12-31T23:59:59.1Z'; Show=$true },
        [pscustomobject]@{ Name='iso-fraction-year-zero'; Value='0000-02-29T00:00:00.123456789Z'; Show=$true },
        [pscustomobject]@{ Name='iso-fraction-field-cap'; Value=$fractionAtFieldCap; Show=$true },
        [pscustomobject]@{ Name='iso-fraction-over-field-cap'; Value=$fractionOverFieldCap; Show=$false },
        [pscustomobject]@{ Name='iso-fraction-empty'; Value='2000-01-01T00:00:00.Z'; Show=$false },
        [pscustomobject]@{ Name='iso-fraction-double-dot'; Value='2000-01-01T00:00:00.1.2Z'; Show=$false },
        [pscustomobject]@{ Name='iso-fraction-nondigit'; Value='2000-01-01T00:00:00.12xZ'; Show=$false },
        [pscustomobject]@{ Name='iso-fraction-offset'; Value='2000-01-01T00:00:00.123+00:00'; Show=$false },
        [pscustomobject]@{ Name='iso-fraction-no-z'; Value='2000-01-01T00:00:00.123'; Show=$false },
        [pscustomobject]@{ Name='iso-lowercase-t'; Value='2000-01-01t00:00:00Z'; Show=$false },
        [pscustomobject]@{ Name='iso-lowercase-z'; Value='2000-01-01T00:00:00z'; Show=$false },
        [pscustomobject]@{ Name='future'; Value=[string]($epochNow + 3600); Show=$false },
        [pscustomobject]@{ Name='overflow'; Value='9999999999999999'; Show=$false },
        [pscustomobject]@{ Name='too-many-digits'; Value='10000000000000000'; Show=$false },
        [pscustomobject]@{ Name='bad-date'; Value='2026-02-30T00:00:00Z'; Show=$false }
    )
    foreach ($vector in $elapsedVectors) {
        $run = Invoke-Subagent (Json ([ordered]@{ tasks=@([ordered]@{ id=$vector.Name; startTime=$vector.Value }) })) $elapsedOnlyConfig @{}
        Check-Run ('WIN-PS1 elapsed ' + $vector.Name) $run
        Check ('WIN-PS1 elapsed semantics ' + $vector.Name) ((@((Get-SubagentRows $run)).Count -eq 1) -eq $vector.Show)
    }

    $emptyTasksText = '{"tasks":[]}'
    $exactCapBytes = $Utf8NoBom.GetBytes((' ' * (4194304 - $emptyTasksText.Length)) + $emptyTasksText)
    $exactCapRun = Invoke-StatuslineBytes $exactCapBytes $nameOnlyConfig @{} '--subagent' 30000
    Check-Run 'WIN-PS1 stdin exact 4194304 bytes' $exactCapRun
    Check 'WIN-PS1 stdin exact cap is accepted silently' ($exactCapRun.StdoutBytes.Length -eq 0)
    $overCapBytes = New-Object byte[] 4194305
    [Array]::Copy($exactCapBytes, $overCapBytes, $exactCapBytes.Length)
    $overCapBytes[$overCapBytes.Length - 1] = 0x20
    $overCapRun = Invoke-StatuslineBytes $overCapBytes $nameOnlyConfig @{} '--subagent' 30000
    Check-Run 'WIN-PS1 stdin cap plus one' $overCapRun
    Check 'WIN-PS1 stdin cap plus one is silent' ($overCapRun.StdoutBytes.Length -eq 0)
    $badUtf8Run = Invoke-StatuslineBytes ([byte[]]@(0x7B,0x22,0xC3,0x28,0x22,0x3A,0x31,0x7D)) $nameOnlyConfig @{} '--subagent' 5000
    Check-Run 'WIN-PS1 malformed UTF-8 stdin' $badUtf8Run
    Check 'WIN-PS1 malformed UTF-8 stdin is silent' ($badUtf8Run.StdoutBytes.Length -eq 0)

    $contentExactConfig = New-Config 'sub-content-exact' @(
        ('VL_SUB_SEGMENTS=' + (Quote-FromConfigure 'name')),
        'VL_NOCOLOR=1',
        ("VL_CAP_L='" + (('x' * 65512) -join '') + "'"),
        "VL_CAP_R=''"
    )
    $contentExactRun = Invoke-Subagent '{"tasks":[{"id":"content-exact","name":"x"}]}' $contentExactConfig @{}
    Check-Run 'WIN-PS1 content exact 65536 bytes' $contentExactRun
    $contentExactRows = @(Get-SubagentRows $contentExactRun)
    Check 'WIN-PS1 content exact cap renders untruncated' ($contentExactRows.Count -eq 1 -and $StrictUtf8.GetByteCount([string]$contentExactRows[0].content) -eq 65536)
    $contentOverConfig = New-Config 'sub-content-over' @(
        ('VL_SUB_SEGMENTS=' + (Quote-FromConfigure 'name')),
        'VL_NOCOLOR=1',
        ("VL_CAP_L='" + (('x' * 65513) -join '') + "'"),
        "VL_CAP_R=''"
    )
    $contentOverRun = Invoke-Subagent '{"tasks":[{"id":"content-over","name":"x"}]}' $contentOverConfig @{}
    Check-Run 'WIN-PS1 content cap plus one' $contentOverRun
    Check 'WIN-PS1 content cap plus one suppresses row' ($contentOverRun.StdoutBytes.Length -eq 0)

    $sidecarRoot = Join-Path $TempRoot 'subagent-sidecar'
    [void][IO.Directory]::CreateDirectory($sidecarRoot)
    $transcript = Join-Path $sidecarRoot 'session.jsonl'
    Write-Utf8 $transcript ''
    $sidecarDir = Join-Path $sidecarRoot 'session\subagents'
    [void][IO.Directory]::CreateDirectory($sidecarDir)
    $sidecar = Join-Path $sidecarDir 'agent-side.meta.json'
    Write-Utf8 $sidecar '{"agentType":"Explore"}'
    $sidePayload = [ordered]@{ transcript_path=(Forward-Path $transcript); tasks=@([ordered]@{ id='side'; name='Payload'; type='local_agent' }) }
    $sideRun = Invoke-Subagent (Json $sidePayload) $nameOnlyConfig @{}
    Check-Run 'WIN-PS1 sidecar positive' $sideRun
    Check 'WIN-PS1 sidecar formula adds role beside payload name' ((Plain (@(Get-SubagentRows $sideRun)[0].content)).Contains('Payload (Explore)'))
    foreach ($separatorPath in @((Forward-Path $transcript), $transcript)) {
        $sidePayload.transcript_path = $separatorPath
        $run = Invoke-Subagent (Json $sidePayload) $nameOnlyConfig @{}
        Check 'WIN-PS1 sidecar accepts native and forward separators' ((Plain (@(Get-SubagentRows $run)[0].content)).Contains('Explore'))
    }
    foreach ($unsafeId in @('side:ads','side/slash','side\slash')) {
        $sidePayload.tasks[0].id = $unsafeId
        $run = Invoke-Subagent (Json $sidePayload) $nameOnlyConfig @{}
        Check 'WIN-PS1 unsafe sidecar id keeps row but not metadata' (@(Get-SubagentRows $run).Count -eq 1 -and -not (Plain (@(Get-SubagentRows $run)[0].content)).Contains('Explore'))
    }
    $sidePayload.tasks[0].id = 'side'
    $fallbackCases = @(
        '\\server\share\session.jsonl',
        '\\?\C:\session.jsonl',
        'Registry::HKEY_CURRENT_USER\session.jsonl',
        'C:\bad..\session.jsonl',
        'C:\CON\session.jsonl',
        'C:\carrier:stream.jsonl',
        ('C:\' + ('x' * 4090) + '.jsonl'),
        ((Split-Path -Path $transcript -Parent) + '\child\..\session.jsonl')
    )
    foreach ($badPath in $fallbackCases) {
        $sidePayload.transcript_path = $badPath
        $run = Invoke-Subagent (Json $sidePayload) $nameOnlyConfig @{}
        Check-Run 'WIN-PS1 unsafe sidecar path fallback' $run
        Check 'WIN-PS1 unsafe sidecar path uses payload identity' (-not (Plain (@(Get-SubagentRows $run)[0].content)).Contains('Explore'))
    }
    $sidePayload.transcript_path = Forward-Path $transcript
    [IO.File]::WriteAllBytes($sidecar, (New-Object byte[] 65537))
    $oversizedSide = Invoke-Subagent (Json $sidePayload) $nameOnlyConfig @{}
    Check 'WIN-PS1 oversized sidecar falls back' (-not (Plain (@(Get-SubagentRows $oversizedSide)[0].content)).Contains('Explore'))
    [IO.File]::WriteAllBytes($sidecar, [byte[]]@(0xC3,0x28))
    $malformedSide = Invoke-Subagent (Json $sidePayload) $nameOnlyConfig @{}
    Check 'WIN-PS1 malformed UTF-8 sidecar falls back' (-not (Plain (@(Get-SubagentRows $malformedSide)[0].content)).Contains('Explore'))
    Write-Utf8 $sidecar '{"agentType":'
    $badJsonSide = Invoke-Subagent (Json $sidePayload) $nameOnlyConfig @{}
    Check 'WIN-PS1 malformed JSON sidecar falls back' (-not (Plain (@(Get-SubagentRows $badJsonSide)[0].content)).Contains('Explore'))
    Write-Utf8 $sidecar '{"agentType":"Explore"}'

    $junctionTarget = Join-Path $TempRoot 'subagent-junction-target'
    $junctionLink = Join-Path $TempRoot 'subagent-junction-link'
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    $junctionTranscript = Join-Path $junctionTarget 'session.jsonl'
    Write-Utf8 $junctionTranscript ''
    [void][IO.Directory]::CreateDirectory((Join-Path $junctionTarget 'session\subagents'))
    Write-Utf8 (Join-Path $junctionTarget 'session\subagents\agent-side.meta.json') '{"agentType":"JunctionRole"}'
    $mkSubJunction = Invoke-CapturedProcess $env:ComSpec ('/d /s /c "mklink /J ""' + $junctionLink + '"" ""' + $junctionTarget + '"""') '' @{} $Repo 5000
    if ($mkSubJunction.ExitCode -eq 0) {
        $sidePayload.transcript_path = Forward-Path (Join-Path $junctionLink 'session.jsonl')
        $junctionRun = Invoke-Subagent (Json $sidePayload) $nameOnlyConfig @{}
        Check 'WIN-PS1 reparse transcript path falls back' (-not (Plain (@(Get-SubagentRows $junctionRun)[0].content)).Contains('JunctionRole'))
    } else { Blocked 'WIN-PS1 reparse transcript path' $mkSubJunction.Stderr }

    $subSideEffectRoot = Join-Path $TempRoot 'subagent-no-main-side-effects'
    $floatTarget = Join-Path $subSideEffectRoot 'float.txt'
    $burnTarget = Join-Path $subSideEffectRoot 'burn.tsv'
    $sideEffectConfig = New-Config 'sub-no-main-side-effects' @(
        ('VL_SUB_SEGMENTS=' + (Quote-FromConfigure 'name')),
        'VL_FLOAT=1',
        ('VL_FLOAT_FILE=' + (Quote-FromConfigure (Forward-Path $floatTarget))),
        'VL_SEGMENTS=git\ burn',
        ('BURN_FILE=' + (Quote-FromConfigure (Forward-Path $burnTarget))),
        'VL_LIMIT_SYNC=1'
    )
    $sideEffectRun = Invoke-Subagent '{"tasks":[{"id":"side-effect","name":"safe"}]}' $sideEffectConfig @{ CORALLINE_NO_SAMPLE=$null }
    Check-Run 'WIN-PS1 subagent avoids main side effects' $sideEffectRun
    Check 'WIN-PS1 subagent creates no float or state artifacts' (-not [IO.File]::Exists($floatTarget) -and -not [IO.File]::Exists($burnTarget) -and -not [IO.Directory]::Exists($burnTarget + '.d'))
    $mainIdentityConfig = New-Config 'sub-main-identity' @('VL_SEGMENTS=model\ ctx','VL_CLOCK=off')
    $mainIdentityPs = Invoke-Statusline (Json $basePayload) $mainIdentityConfig @{} '' 5000
    $mainIdentityBash = Invoke-BashStatusline (Json $basePayload) $mainIdentityConfig @{}
    Check-Run 'WIN-PS1 main fixture identity after subagent implementation' $mainIdentityPs
    Check-Exact 'WIN-PS1 main fixture remains byte exact' $mainIdentityPs $mainIdentityBash

    $quotedSegments = Quote-FromConfigure 'dir git model ctx'
    Check 'real configure shell_quote emits escaped multi-word value' ($quotedSegments.Contains('\ '))
    $quotedConfig = New-Config 'configure-q-segments' @("VL_SEGMENTS=$quotedSegments", 'VL_CLOCK=off')
    $quotedRun = Invoke-Statusline (Json $basePayload) $quotedConfig @{} '' 5000
    Check-Run 'configure %q segment list' $quotedRun
    $quotedPlain = Plain $quotedRun.Stdout
    Check 'configure %q segment list renders every token' ($quotedPlain.Contains($repoLeaf) -and $quotedPlain.Contains('main') -and $quotedPlain.Contains('MODEL_SENTINEL') -and $quotedPlain.Contains('62%'))

    $caseConfig = New-Config 'case-sensitive-keys' @(
        'VL_SEGMENTS=model',
        'vl_segments=clock',
        'VL_CLOCK=off',
        'VL_BG_MODEL=56',
        'vl_bg_model=196'
    )
    $casePs = Invoke-Statusline (Json $basePayload) $caseConfig @{} '' 5000
    $caseBash = Invoke-BashStatusline (Json $basePayload) $caseConfig @{}
    Check-Run 'PowerShell case-sensitive config keys' $casePs
    Check-Run 'Bash case-sensitive config keys' $caseBash
    Check-Exact 'case-variant config keys cannot overwrite supported keys' $casePs $caseBash
    Check 'case-sensitive config keeps the model segment' ((Plain $casePs.Stdout).Contains('MODEL_SENTINEL'))

    $segmentCaseConfig = New-Config 'case-sensitive-segment-name' @('VL_SEGMENTS=CLOCK', 'VL_CLOCK=24h')
    $segmentCasePs = Invoke-Statusline (Json $basePayload) $segmentCaseConfig @{} '' 5000
    $segmentCaseBash = Invoke-BashStatusline (Json $basePayload) $segmentCaseConfig @{}
    Check-Run 'PowerShell case-sensitive segment name' $segmentCasePs
    Check-Run 'Bash case-sensitive segment name' $segmentCaseBash
    Check-Exact 'case-variant segment name stays unknown' $segmentCasePs $segmentCaseBash
    Check 'case-variant segment name renders nothing' ([string]::IsNullOrEmpty($segmentCasePs.Stdout))

    $clockOffCaseConfig = New-Config 'case-sensitive-clock-off' @('VL_SEGMENTS=clock', 'VL_CLOCK=OFF', 'VL_CLOCK_SECONDS=0')
    $clockOffCasePs = Invoke-Statusline (Json $basePayload) $clockOffCaseConfig @{} '' 5000
    Check-Run 'PowerShell case-sensitive clock off value' $clockOffCasePs
    Check 'case-variant OFF keeps the Bash 12h fallback' ((Plain $clockOffCasePs.Stdout) -match '\b(0[1-9]|1[0-2]):[0-5][0-9] (am|pm)\b')

    $clock24CaseConfig = New-Config 'case-sensitive-clock-24h' @('VL_SEGMENTS=clock', 'VL_CLOCK=24H', 'VL_CLOCK_SECONDS=0')
    $clock24CasePs = Invoke-Statusline (Json $basePayload) $clock24CaseConfig @{} '' 5000
    Check-Run 'PowerShell case-sensitive clock 24h value' $clock24CasePs
    Check 'case-variant 24H keeps the Bash 12h fallback' ((Plain $clock24CasePs.Stdout) -match '\b(0[1-9]|1[0-2]):[0-5][0-9] (am|pm)\b')

    $styleCaseConfig = New-Config 'case-sensitive-style-value' @('VL_SEGMENTS=model\ ctx', 'VL_CLOCK=off', 'VL_STYLE=CLASSIC')
    $styleCasePs = Invoke-Statusline (Json $basePayload) $styleCaseConfig @{} '' 5000
    $styleCaseBash = Invoke-BashStatusline (Json $basePayload) $styleCaseConfig @{}
    Check-Run 'PowerShell case-sensitive style value' $styleCasePs
    Check-Run 'Bash case-sensitive style value' $styleCaseBash
    Check-Exact 'case-variant style value keeps pill fallback' $styleCasePs $styleCaseBash

    $layoutCaseConfig = New-Config 'case-sensitive-layout-value' @('VL_LAYOUT=AUTO', 'VL_SEGMENTS=model', 'VL_SEGMENTS2=ctx', 'VL_CLOCK=off')
    $layoutCasePs = Invoke-Statusline (Json $basePayload) $layoutCaseConfig @{ COLUMNS='1' } '' 5000
    $layoutCaseBash = Invoke-BashStatusline (Json $basePayload) $layoutCaseConfig @{ COLUMNS='1' }
    Check-Run 'PowerShell case-sensitive layout value' $layoutCasePs
    Check-Run 'Bash case-sensitive layout value' $layoutCaseBash
    Check-Exact 'case-variant layout value keeps fixed rows' $layoutCasePs $layoutCaseBash

    $paddedQuote = Quote-FromConfigure ' model '
    $paddedLine = 'VL_SEGMENTS=' + $paddedQuote
    $paddedConfig = New-Config 'configure-q-padded' @($paddedLine, 'VL_CLOCK=off')
    $paddedRun = Invoke-Statusline (Json $basePayload) $paddedConfig @{} '' 5000
    Check-Run 'configure %q leading and trailing spaces' $paddedRun
    Check 'configure %q preserves one padded shell word' ((Plain $paddedRun.Stdout).Contains('MODEL_SENTINEL') -and -not (Plain $paddedRun.Stdout).Contains((Glyph 0x2299)))

    $spaceRoot = Join-Path $TempRoot 'space root'
    [void][System.IO.Directory]::CreateDirectory($spaceRoot)
    $spaceTheme = Join-Path $spaceRoot 'space theme.conf'
    Write-Utf8 $spaceTheme "VL_BG_MODEL=33`n"
    $quotedInclude = Quote-FromConfigure (Forward-Path $spaceTheme)
    $spaceConfig = Join-Path $spaceRoot 'coralline.conf'
    Write-Utf8 $spaceConfig ('. ' + $quotedInclude + "`nVL_SEGMENTS=model`nVL_CLOCK=off`n")
    [void](Run-ModelColor 'configure %q spaced include' $spaceConfig '33' @{})

    $wordConfig = New-Config 'word-forms' @(
        "VL_SEGMENTS='model'",
        'VL_CLOCK="off"',
        'VL_BG_MODEL=44'
    )
    [void](Run-ModelColor 'single and double shell words' $wordConfig '44' @{})
    $windowsPathConfig = New-Config 'double-quoted-windows-path' @(
        'VL_SEGMENTS=model',
        'VL_CLOCK=off',
        'VL_BG_MODEL=45',
        'VL_FLOAT_FILE="C:\Users\Jane\.claude\float.txt"'
    )
    $windowsPathPs = Invoke-Statusline (Json $basePayload) $windowsPathConfig @{} '' 5000
    $windowsPathBash = Invoke-BashStatusline (Json $basePayload) $windowsPathConfig @{}
    Check-Run 'PowerShell double-quoted Windows path' $windowsPathPs
    Check-Run 'Bash double-quoted Windows path' $windowsPathBash
    Check-Exact 'double-quoted ordinary backslashes are byte exact' $windowsPathPs $windowsPathBash
    Check 'double-quoted Windows path keeps the root config active' ($windowsPathPs.Stdout.Contains('48;5;45m'))

    $bareConfig = New-Config 'bare-escape' @('VL_SEGMENTS=model\ ctx', 'VL_CLOCK=off')
    $bareRun = Invoke-Statusline (Json $basePayload) $bareConfig @{} '' 5000
    Check-Run 'bare backslash shell word' $bareRun
    Check 'bare backslash shell word decodes spaces' ((Plain $bareRun.Stdout).Contains('MODEL_SENTINEL') -and (Plain $bareRun.Stdout).Contains('62%'))

    $controlQuote = Quote-FromConfigure ("X`nY")
    Check 'real configure quote selects ANSI-C for newline' ($controlQuote.StartsWith("$'", [System.StringComparison]::Ordinal))
    $ansiConfig = New-Config 'ansi-c' @('VL_SEGMENTS=ctx', 'VL_CLOCK=off', "VL_CTX_GLYPH=$controlQuote")
    $ansiRun = Invoke-Statusline (Json $basePayload) $ansiConfig @{} '' 5000
    Check-Run 'ANSI-C percent-q decode' $ansiRun
    Check 'decoded config controls are scrubbed before render' ((Plain $ansiRun.Stdout).Contains('XY') -and -not (Plain $ansiRun.Stdout).Contains("X`nY"))

    $themeInclude = Quote-FromConfigure (Forward-Path (Join-Path $Repo 'themes\dracula.conf'))
    $themeConfig = New-Config 'shipped-theme' @(('. ' + $themeInclude), 'VL_SEGMENTS=model', 'VL_CLOCK=off')
    [void](Run-ModelColor 'approved runtime theme include' $themeConfig '189,147,249' @{})

    $homeRoot = Join-Path $TempRoot 'fake-home'
    $homeThemes = Join-Path $homeRoot 'themes'
    [void][System.IO.Directory]::CreateDirectory($homeThemes)
    foreach ($name in @('dollar','braced','tilde')) { Write-Utf8 (Join-Path $homeThemes "$name.conf") "VL_BG_MODEL=55`n" }
    foreach ($case in @(
        [pscustomobject]@{ Name='HOME include'; Word='$HOME/themes/dollar.conf' },
        [pscustomobject]@{ Name='braced HOME include'; Word='${HOME}/themes/braced.conf' },
        [pscustomobject]@{ Name='tilde include'; Word='~/themes/tilde.conf' }
    )) {
        $config = Join-Path $homeRoot ($case.Name.Replace(' ','-') + '.conf')
        Write-Utf8 $config ('. ' + $case.Word + "`nVL_SEGMENTS=model`nVL_CLOCK=off`n")
        [void](Run-ModelColor $case.Name $config '55' @{ HOME=$homeRoot; USERPROFILE=$homeRoot })
    }
    $homePrefixTarget = $homeRoot + '_BACKUP'
    [void][System.IO.Directory]::CreateDirectory($homePrefixTarget)
    $homePrefixFloat = Join-Path $homePrefixTarget 'float.txt'
    $homePrefixConfig = New-Config 'HOME-variable-boundary' @(
        'VL_SEGMENTS=model',
        'VL_CLOCK=off',
        'VL_FLOAT=1',
        'VL_FLOAT_SEGMENTS=model',
        'VL_FLOAT_FILE=$HOME_BACKUP/float.txt'
    )
    $homePrefixRun = Invoke-Statusline (Json $basePayload) $homePrefixConfig @{ HOME=$homeRoot; USERPROFILE=$homeRoot } '' 5000
    Check-Run 'PowerShell HOME variable boundary' $homePrefixRun
    Check 'longer HOME-prefixed variable cannot authorize float output' (-not [System.IO.File]::Exists($homePrefixFloat))
    $quotedHomePrefixConfig = New-Config 'quoted-HOME-variable-boundary' @(
        'VL_SEGMENTS=model',
        'VL_CLOCK=off',
        'VL_FLOAT=1',
        'VL_FLOAT_SEGMENTS=model',
        'VL_FLOAT_FILE="$HOME_BACKUP/float.txt"'
    )
    $quotedHomePrefixRun = Invoke-Statusline (Json $basePayload) $quotedHomePrefixConfig @{ HOME=$homeRoot; USERPROFILE=$homeRoot } '' 5000
    Check-Run 'PowerShell quoted HOME variable boundary' $quotedHomePrefixRun
    Check 'quoted longer HOME-prefixed variable cannot authorize float output' (-not [System.IO.File]::Exists($homePrefixFloat))

    $driveConfig = New-Config 'msys-root' @('VL_SEGMENTS=model', 'VL_CLOCK=off', 'VL_BG_MODEL=56')
    $drivePath = Forward-Path $driveConfig
    $msysConfig = '/' + $drivePath.Substring(0,1).ToLowerInvariant() + $drivePath.Substring(2)
    $msysRun = Invoke-Statusline (Json $basePayload) $msysConfig @{} '' 5000
    Check-Run 'MSYS root config path' $msysRun
    Check 'MSYS root config path applies config' ($msysRun.Stdout.Contains('48;5;56m'))

    $includeDir = Join-Path $TempRoot 'transactions'
    [void][System.IO.Directory]::CreateDirectory($includeDir)
    $good = Join-Path $includeDir 'good.conf'
    Write-Utf8 $good "VL_BG_MODEL=61`n"
    $beforeAfter = Join-Path $includeDir 'before-after.conf'
    Write-Utf8 $beforeAfter "VL_SEGMENTS=model`nVL_CLOCK=off`nVL_BG_MODEL=60`n. good.conf`nVL_BG_MODEL=62`n"
    [void](Run-ModelColor 'assignment before and after include' $beforeAfter '62' @{})

    $missing = Join-Path $includeDir 'missing-root.conf'
    Write-Utf8 $missing "VL_SEGMENTS=model`nVL_CLOCK=off`n. missing.conf`nVL_BG_MODEL=63`n"
    [void](Run-ModelColor 'missing include is nested no-op' $missing '63' @{})

    $invalidChild = Join-Path $includeDir 'invalid-child.conf'
    Write-Utf8 $invalidChild "VL_BG_MODEL=99`necho unsupported`n"
    $invalidChildRoot = Join-Path $includeDir 'invalid-child-root.conf'
    Write-Utf8 $invalidChildRoot "VL_SEGMENTS=model`nVL_CLOCK=off`nVL_BG_MODEL=64`n. invalid-child.conf`n"
    [void](Run-ModelColor 'malformed include rolls back only include delta' $invalidChildRoot '64' @{})

    $cycleA = Join-Path $includeDir 'cycle-a.conf'
    $cycleB = Join-Path $includeDir 'cycle-b.conf'
    Write-Utf8 $cycleA "VL_SEGMENTS=model`nVL_CLOCK=off`n. cycle-b.conf`n"
    Write-Utf8 $cycleB "VL_BG_MODEL=65`n. cycle-a.conf`n"
    [void](Run-ModelColor 'include cycle is silent no-op at cycle edge' $cycleA '65' @{})

    $depthDir = Join-Path $includeDir 'depth'
    [void][System.IO.Directory]::CreateDirectory($depthDir)
    for ($i=1; $i -le 9; $i++) {
        $lines = @("VL_BG_MODEL=$($i + 70)")
        if ($i -lt 9) { $lines += ". d$($i + 1).conf" }
        Write-Utf8 (Join-Path $depthDir "d$i.conf") (($lines -join "`n") + "`n")
    }
    $depthRoot = Join-Path $depthDir 'root.conf'
    Write-Utf8 $depthRoot "VL_SEGMENTS=model`nVL_CLOCK=off`n. d1.conf`n"
    [void](Run-ModelColor 'include depth eight commits and depth nine is no-op' $depthRoot '78' @{})

    $outsideDir = Join-Path $TempRoot 'outside'
    [void][System.IO.Directory]::CreateDirectory($outsideDir)
    Write-Utf8 (Join-Path $outsideDir 'evil.conf') "VL_BG_MODEL=99`n"
    $outRoot = Join-Path $includeDir 'out-root.conf'
    Write-Utf8 $outRoot "VL_SEGMENTS=model`nVL_CLOCK=off`n. ../outside/evil.conf`nVL_BG_MODEL=66`n"
    [void](Run-ModelColor 'out-of-root include is nested no-op' $outRoot '66' @{})

    $malformedRoot = Join-Path $includeDir 'malformed-root.conf'
    Write-Utf8 $malformedRoot "VL_SEGMENTS=model`nVL_CLOCK=off`nVL_BG_MODEL=99`necho unsupported`n"
    [void](Run-ModelColor 'malformed root rolls back all root assignments' $malformedRoot '173' @{})
    $includeThenBad = Join-Path $includeDir 'include-then-bad.conf'
    Write-Utf8 $includeThenBad "VL_SEGMENTS=model`nVL_CLOCK=off`n. good.conf`necho unsupported`n"
    [void](Run-ModelColor 'successful include delta rolls back with malformed root' $includeThenBad '173' @{})

    foreach ($bad in @(
        [pscustomobject]@{ Name='command substitution'; Value='$(whoami)' },
        [pscustomobject]@{ Name='backtick'; Value='`whoami`' },
        [pscustomobject]@{ Name='pipeline'; Value='model|ctx' },
        [pscustomobject]@{ Name='redirect'; Value='model>file' },
        [pscustomobject]@{ Name='semicolon'; Value='model;ctx' },
        [pscustomobject]@{ Name='multiple words'; Value='model ctx' },
        [pscustomobject]@{ Name='incomplete escape'; Value='model\' }
    )) {
        $config = Join-Path $includeDir ('reject-' + $bad.Name.Replace(' ','-') + '.conf')
        Write-Utf8 $config ("VL_BG_MODEL=99`nVL_SEGMENTS=$($bad.Value)`n")
        [void](Run-ModelColor ("reject " + $bad.Name) $config '173' @{})
    }

    $conditional = Join-Path $includeDir 'conditional.conf'
    # Safe-subset rule: parser control flow reads REMORA_ACTIVE only from the process environment.
    Write-Utf8 $conditional @'
VL_SEGMENTS=model
VL_CLOCK=off
REMORA_ACTIVE=1
if [ "${REMORA_ACTIVE:-0}" = "1" ]; then
VL_BG_MODEL=81
else
VL_BG_MODEL=82
fi
'@
    foreach ($case in @(
        [pscustomobject]@{ Name='REMORA unset uses zero'; Env=@{}; Color='82' },
        [pscustomobject]@{ Name='REMORA empty uses zero'; Env=@{ REMORA_ACTIVE='' }; Color='82' },
        [pscustomobject]@{ Name='REMORA zero selects else'; Env=@{ REMORA_ACTIVE='0' }; Color='82' },
        [pscustomobject]@{ Name='REMORA one selects then'; Env=@{ REMORA_ACTIVE='1' }; Color='81' }
    )) { [void](Run-ModelColor $case.Name $conditional $case.Color $case.Env) }

    $notEqual = Join-Path $includeDir 'conditional-ne.conf'
    Write-Utf8 $notEqual @'
VL_SEGMENTS=model
VL_CLOCK=off
if [ "${REMORA_ACTIVE:-0}" != "1" ]; then
VL_BG_MODEL=83
else
VL_BG_MODEL=84
fi
'@
    [void](Run-ModelColor 'REMORA not-equal true branch' $notEqual '83' @{ REMORA_ACTIVE='0' })
    [void](Run-ModelColor 'REMORA not-equal else branch' $notEqual '84' @{ REMORA_ACTIVE='1' })

    $inactive = Join-Path $includeDir 'inactive.conf'
    Write-Utf8 $inactive @'
VL_SEGMENTS=model
VL_CLOCK=off
if [ "${REMORA_ACTIVE:-0}" = "1" ]; then
VL_BG_MODEL=$(unsupported)
. missing.conf
else
VL_BG_MODEL=85
fi
'@
    [void](Run-ModelColor 'inactive branch assignments and includes have no effect' $inactive '85' @{ REMORA_ACTIVE='0' })
    $unsupportedIf = Join-Path $includeDir 'unsupported-if.conf'
    Write-Utf8 $unsupportedIf "VL_BG_MODEL=99`nif test -n x; then`nVL_BG_MODEL=1`nfi`n"
    [void](Run-ModelColor 'unsupported conditional rolls back root' $unsupportedIf '173' @{})

    $budgetDir = Join-Path $includeDir 'budget'
    [void][System.IO.Directory]::CreateDirectory($budgetDir)
    Write-Utf8 (Join-Path $budgetDir 'target16.conf') "VL_BG_MODEL=91`n"
    Write-Utf8 (Join-Path $budgetDir 'target17.conf') "VL_BG_MODEL=92`n"
    Write-Utf8 (Join-Path $budgetDir 'dup.conf') "VL_FG_DIM=1`n"
    foreach ($kind in @('missing','duplicate','cycle','rejected')) {
        $root = Join-Path $budgetDir ("budget-$kind.conf")
        $lines = @('VL_SEGMENTS=model','VL_CLOCK=off')
        for ($i=1; $i -le 15; $i++) {
            switch ($kind) {
                'missing' { $lines += ". missing-$i.conf" }
                'duplicate' { $lines += '. dup.conf' }
                'cycle' { $lines += ('. ' + [System.IO.Path]::GetFileName($root)) }
                'rejected' { $lines += '. ../../outside/evil.conf' }
            }
        }
        $lines += '. target16.conf'
        $lines += '. target17.conf'
        $lines += 'VL_FG_TEXT=42'
        Write-Utf8 $root (($lines -join "`n") + "`n")
        $run = Run-ModelColor ("include budget counts $kind attempts") $root '91' @{}
        Check "include budget $kind leaves later root assignment live" ($run.Stdout.Contains('38;5;42m'))
        Check "include budget $kind makes seventeenth a complete no-op" (-not $run.Stdout.Contains('48;5;92m'))
    }

    $inactiveBudget = Join-Path $budgetDir 'inactive-budget.conf'
    $inactiveLines = @('VL_SEGMENTS=model','VL_CLOCK=off','if [ "${REMORA_ACTIVE:-0}" = "1" ]; then')
    for ($i=1; $i -le 20; $i++) { $inactiveLines += ". inactive-$i.conf" }
    $inactiveLines += 'else'
    for ($i=1; $i -le 15; $i++) { $inactiveLines += ". active-missing-$i.conf" }
    $inactiveLines += '. target16.conf'
    $inactiveLines += 'fi'
    Write-Utf8 $inactiveBudget (($inactiveLines -join "`n") + "`n")
    [void](Run-ModelColor 'inactive includes consume no shared budget' $inactiveBudget '91' @{ REMORA_ACTIVE='0' })

    $baseConfigLines = @('VL_CLOCK=off')
    $burnPayload = Clone-Object $basePayload
    $burnPayload.rate_limits.five_hour.used_percentage = $null
    $burnPayload.rate_limits.five_hour.resets_at = $null
    $burnPayload.rate_limits.seven_day.used_percentage = '30'
    $burnPayload.rate_limits.seven_day.resets_at = '1345600'
    $segmentCases = [ordered]@{
        burn = [pscustomobject]@{ Show=@('VL_SEGMENTS=burn','VL_CLOCK=off'); Needle=((Glyph 0x2197) + ' 7d ' + (Glyph 0x21E2)); Payload=$burnPayload; Environment=@{CORALLINE_TEST_NOW='1000000'}; Suppress={ param($p) $p.rate_limits.five_hour.used_percentage=$null; $p.rate_limits.seven_day.used_percentage=$null; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=burn' }
        clock = [pscustomobject]@{ Show=@('VL_SEGMENTS=clock','VL_CLOCK=24h','VL_CLOCK_SECONDS=0'); Needle=(Glyph 0x2299); Suppress={ param($p) $p }; SuppressConfig=@('VL_SEGMENTS=clock','VL_CLOCK=off') }
        cost = [pscustomobject]@{ Show=@('VL_SEGMENTS=cost','VL_CLOCK=off'); Needle='$1.23'; Suppress={ param($p) $p.cost.total_cost_usd=0; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=cost' }
        ctx = [pscustomobject]@{ Show=@('VL_SEGMENTS=ctx','VL_CLOCK=off'); Needle='62%'; Suppress={ param($p) $p.context_window.used_percentage=$null; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=ctx' }
        dir = [pscustomobject]@{ Show=@('VL_SEGMENTS=dir','VL_CLOCK=off'); Needle=$repoLeaf; Suppress={ param($p) $p.cwd=''; $p.workspace.current_dir=''; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=dir' }
        duration = [pscustomobject]@{ Show=@('VL_SEGMENTS=duration','VL_CLOCK=off'); Needle='1h30m'; Suppress={ param($p) $p.cost.total_duration_ms=0; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=duration' }
        effort = [pscustomobject]@{ Show=@('VL_SEGMENTS=effort','VL_CLOCK=off'); Needle='high'; Suppress={ param($p) $p.effort.level=''; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=effort' }
        git = [pscustomobject]@{ Show=@('VL_SEGMENTS=git','VL_CLOCK=off'); Needle='main'; Suppress={ param($p) $p.cwd='C:/tmp/coralline-win01-no-repo'; $p.workspace.current_dir=$p.cwd; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=git' }
        limit5h = [pscustomobject]@{ Show=@('VL_SEGMENTS=limit5h','VL_CLOCK=off'); Needle='41%'; Suppress={ param($p) $p.rate_limits.five_hour.used_percentage=$null; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=limit5h' }
        limit7d = [pscustomobject]@{ Show=@('VL_SEGMENTS=limit7d','VL_CLOCK=off'); Needle='79%'; Suppress={ param($p) $p.rate_limits.seven_day.used_percentage=$null; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=limit7d' }
        lines = [pscustomobject]@{ Show=@('VL_SEGMENTS=lines','VL_CLOCK=off'); Needle='+321 -87'; Suppress={ param($p) $p.cost.total_lines_added=0; $p.cost.total_lines_removed=0; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=lines' }
        model = [pscustomobject]@{ Show=@('VL_SEGMENTS=model','VL_CLOCK=off'); Needle='MODEL_SENTINEL'; Suppress={ param($p) $p.model.display_name=''; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=model' }
        node = [pscustomobject]@{ Show=@('VL_SEGMENTS=node','VL_CLOCK=off'); Needle='20.11.1'; Suppress={ param($p) $p.cwd='C:/tmp/coralline-win01-no-pin'; $p.workspace.current_dir=$p.cwd; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=node' }
        project = [pscustomobject]@{ Show=@('VL_SEGMENTS=project','VL_CLOCK=off'); Needle=[System.IO.Path]::GetFileName($gitRoot); Suppress={ param($p) $p.cwd=''; $p.workspace.current_dir=''; $p }; SuppressConfig=@('VL_SEGMENTS=dir\ project','VL_CLOCK=off') }
        python = [pscustomobject]@{ Show=@('VL_SEGMENTS=python','VL_CLOCK=off'); Needle='3.12.2'; Suppress={ param($p) $p.cwd='C:/tmp/coralline-win01-no-pin'; $p.workspace.current_dir=$p.cwd; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=python' }
        stash = [pscustomobject]@{ Show=@('VL_SEGMENTS=stash','VL_CLOCK=off'); Needle='1'; Suppress={ param($p) $p.cwd='C:/tmp/coralline-win01-no-repo'; $p.workspace.current_dir=$p.cwd; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=stash' }
        style = [pscustomobject]@{ Show=@('VL_SEGMENTS=style','VL_CLOCK=off'); Needle='Explanatory'; Suppress={ param($p) $p.output_style.name='default'; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=style' }
    }

    foreach ($name in $expectedRegistry) {
        $case = $segmentCases[$name]
        $showPayload = $basePayload
        if ($null -ne $case.PSObject.Properties['Payload']) { $showPayload = $case.Payload }
        $caseEnvironment = @{}
        if ($null -ne $case.PSObject.Properties['Environment']) { $caseEnvironment = $case.Environment }
        $showConfig = New-Config ("segment-$name-show") $case.Show
        $show = Invoke-Statusline (Json $showPayload) $showConfig $caseEnvironment '' 5000
        Check-Run "$name show" $show
        Check "$name show/value" ((Plain $show.Stdout).Contains([string]$case.Needle))
        $suppressedPayload = Clone-Object $showPayload
        $suppressedPayload = & $case.Suppress $suppressedPayload
        $suppressConfig = New-Config ("segment-$name-suppress") $case.SuppressConfig
        $suppress = Invoke-Statusline (Json $suppressedPayload) $suppressConfig $caseEnvironment '' 5000
        Check-Run "$name suppress" $suppress
        Check "$name suppresses without an empty pill" ([string]::IsNullOrEmpty($suppress.Stdout))
    }

    $orderedNames = @('dir','project','git','node','python','model','effort','ctx','limit5h','limit7d','lines','cost','style','duration','stash')
    $orderedValue = $orderedNames -join ' '
    $orderConfig = New-Config 'segment-order' @(('VL_SEGMENTS=' + (Quote-FromConfigure $orderedValue)), 'VL_CLOCK=off')
    $orderRun = Invoke-Statusline (Json $basePayload) $orderConfig @{} '' 5000
    Check-Run 'configured segment order' $orderRun
    $visible = Plain $orderRun.Stdout
    $needles = @($repoLeaf, $repoLeaf, 'main', '20.11.1', '3.12.2', 'MODEL_SENTINEL', 'high', '62%', '5h', '7d', '+321 -87', '$1.23', 'Explanatory', '1h30m', ((Glyph 0x2691) + ' 1'))
    $lastIndex = -1
    $orderOk = $true
    foreach ($needle in $needles) {
        $nextIndex = $visible.IndexOf($needle, $lastIndex + 1, [System.StringComparison]::Ordinal)
        if ($nextIndex -le $lastIndex) { $orderOk = $false; break }
        $lastIndex = $nextIndex
    }
    Check 'configured segment order is preserved exactly' $orderOk

    $bashOrder = Invoke-BashStatusline (Json $basePayload) $orderConfig @{}
    Check-Run 'Bash full stateless oracle' $bashOrder
    Check-Exact 'full fixed-pill differential is byte exact' $orderRun $bashOrder
    if (-not ($orderRun.Stdout -ceq $bashOrder.Stdout)) { [Console]::Out.WriteLine('DIAG  order-config=' + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($orderConfig))) }

    $crossListRoot = Join-Path $TempRoot 'fixed-cross-list-no-repo'
    [void][IO.Directory]::CreateDirectory($crossListRoot)
    $crossListGitProbe = Invoke-CapturedProcess $script:GitExe 'rev-parse --show-toplevel' '' @{} $crossListRoot 5000
    Check 'WIN-03 fixed cross-list fixture has no enclosing Git repository' (-not $crossListGitProbe.TimedOut -and $crossListGitProbe.ExitCode -ne 0)
    $crossListPath = Forward-Path $crossListRoot
    $crossListPayload = Clone-Object $basePayload
    $crossListPayload.cwd = $crossListPath
    $crossListPayload.workspace.current_dir = $crossListPath
    $crossListConfig = New-Config 'fixed-cross-list-project-dir' @('VL_LAYOUT=fixed','VL_SEGMENTS=project','VL_SEGMENTS2=dir','VL_CLOCK=off')
    $crossListPs = Invoke-Statusline (Json $crossListPayload) $crossListConfig @{} '' 5000
    $crossListBash = Invoke-BashStatusline (Json $crossListPayload) $crossListConfig @{}
    Check-Run 'WIN-03 PowerShell fixed cross-list project dir' $crossListPs
    Check-Run 'WIN-03 Bash fixed cross-list project dir' $crossListBash
    Check-Exact 'WIN-03 fixed cross-list project dir differential' $crossListPs $crossListBash
    $crossListRows = @($crossListPs.Stdout.Split([char]"`n") | Where-Object { $_.Length -gt 0 })
    Check 'WIN-03 fixed cross-list project dir emits one row' ($crossListRows.Count -eq 1)

    $themePs = Invoke-Statusline (Json $basePayload) $themeConfig @{} '' 5000
    $themeBash = Invoke-BashStatusline (Json $basePayload) $themeConfig @{}
    Check-Run 'PowerShell theme differential input' $themePs
    Check-Run 'Bash theme differential input' $themeBash
    Check-Exact 'theme include differential is byte exact' $themePs $themeBash

    $glyphConfig = New-Config 'glyph-knobs' @(
        'VL_SEGMENTS=project\ ctx',
        'VL_CLOCK=off',
        'VL_BAR_FILL=F',
        'VL_BAR_EMPTY=E',
        'VL_CTX_GLYPH=C',
        'VL_PROJECT_GLYPH=P'
    )
    $glyphRun = Invoke-Statusline (Json $basePayload) $glyphConfig @{} '' 5000
    Check-Run 'four documented glyph knobs' $glyphRun
    $glyphPlain = Plain $glyphRun.Stdout
    Check 'project and ctx glyph overrides render' ($glyphPlain.Contains(' P ') -and $glyphPlain.Contains(' C '))
    Check 'bar fill and empty overrides render' ($glyphPlain.Contains('FFFEE'))

    $missingTokens = Clone-Object $basePayload
    $missingTokens.context_window.total_input_tokens = $null
    $missingTokens.context_window.total_output_tokens = $null
    $missingTokens.context_window.current_usage.cache_read_input_tokens = $null
    $missingTokens.context_window.current_usage.cache_creation_input_tokens = $null
    $tokenConfig = New-Config 'missing-tokens' @('VL_SEGMENTS=ctx','VL_CLOCK=off')
    $tokenRun = Invoke-Statusline (Json $missingTokens) $tokenConfig @{} '' 5000
    Check-Run 'missing token values' $tokenRun
    Check 'missing token values render zero' ((Plain $tokenRun.Stdout).Contains((Glyph 0x2191) + '0 ' + (Glyph 0x2193) + '0 cr:0 cw:0'))

    $ctxCostOffConfig = New-Config 'ctx-cost-matrix-off' @('VL_SEGMENTS=ctx\ cost','VL_CLOCK=off','VL_NOCOLOR=1','VL_COST_DECIMALS=3')
    $ctxCostOnConfig = New-Config 'ctx-cost-matrix-on' @('VL_SEGMENTS=ctx\ cost','VL_CLOCK=off','VL_NOCOLOR=1','VL_COST_DECIMALS=3','VL_CTX_ALWAYS_SHOW=1','VL_COST_ALWAYS_SHOW=1')
    $ctxCostMatrix = @(
        [pscustomobject]@{ Name='missing'; Raw='{}'; OffCtx=$false; OffCost=$false; OnCtx=$true; OnCost=$true },
        [pscustomobject]@{ Name='null parents'; Raw='{"context_window":null,"cost":null}'; OffCtx=$false; OffCost=$false; OnCtx=$true; OnCost=$true },
        [pscustomobject]@{ Name='null leaves'; Raw='{"context_window":{"used_percentage":null},"cost":{"total_cost_usd":null}}'; OffCtx=$false; OffCost=$false; OnCtx=$true; OnCost=$true },
        [pscustomobject]@{ Name='empty'; Raw='{"context_window":{"used_percentage":""},"cost":{"total_cost_usd":""}}'; OffCtx=$false; OffCost=$false; OnCtx=$true; OnCost=$true },
        [pscustomobject]@{ Name='zero'; Raw='{"context_window":{"used_percentage":0,"total_input_tokens":0,"total_output_tokens":0,"current_usage":{"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"cost":{"total_cost_usd":0}}'; OffCtx=$true; OffCost=$false; OnCtx=$true; OnCost=$true }
    )
    foreach ($case in $ctxCostMatrix) {
        $offPs = Invoke-Statusline $case.Raw $ctxCostOffConfig @{} '' 5000
        $offBash = Invoke-BashStatusline $case.Raw $ctxCostOffConfig @{}
        $onPs = Invoke-Statusline $case.Raw $ctxCostOnConfig @{} '' 5000
        $onBash = Invoke-BashStatusline $case.Raw $ctxCostOnConfig @{}
        Check-Run ('PowerShell ctx/cost matrix off ' + $case.Name) $offPs
        Check-Run ('Bash ctx/cost matrix off ' + $case.Name) $offBash
        Check-Run ('PowerShell ctx/cost matrix on ' + $case.Name) $onPs
        Check-Run ('Bash ctx/cost matrix on ' + $case.Name) $onBash
        Check-Exact ('ctx/cost matrix off differential ' + $case.Name) $offPs $offBash
        Check-Exact ('ctx/cost matrix on differential ' + $case.Name) $onPs $onBash
        $offText = Plain $offPs.Stdout
        $onText = Plain $onPs.Stdout
        Check ('ctx/cost matrix off ctx semantics ' + $case.Name) (($offText.Contains('0%') -and $offText.Contains((Glyph 0x2191) + '0 ' + (Glyph 0x2193) + '0 cr:0 cw:0')) -eq $case.OffCtx)
        Check ('ctx/cost matrix off cost semantics ' + $case.Name) (($offText.Contains('$0.000')) -eq $case.OffCost)
        Check ('ctx/cost matrix on ctx semantics ' + $case.Name) (($onText.Contains('0%') -and $onText.Contains((Glyph 0x2191) + '0 ' + (Glyph 0x2193) + '0 cr:0 cw:0')) -eq $case.OnCtx)
        Check ('ctx/cost matrix on cost semantics ' + $case.Name) (($onText.Contains('$0.000')) -eq $case.OnCost)
    }

    $invalidParentMatrix = @(
        [pscustomobject]@{ Name='context parent bool'; Raw='{"context_window":false}'; Ctx=$false; Cost=$true },
        [pscustomobject]@{ Name='context parent array'; Raw='{"context_window":[]}'; Ctx=$false; Cost=$true },
        [pscustomobject]@{ Name='context leaf bool'; Raw='{"context_window":{"used_percentage":false}}'; Ctx=$false; Cost=$true },
        [pscustomobject]@{ Name='context leaf array'; Raw='{"context_window":{"used_percentage":[1]}}'; Ctx=$false; Cost=$true },
        [pscustomobject]@{ Name='context leaf object'; Raw='{"context_window":{"used_percentage":{}}}'; Ctx=$false; Cost=$true },
        [pscustomobject]@{ Name='context leaf float text'; Raw='{"context_window":{"used_percentage":"not-a-percent"}}'; Ctx=$true; Cost=$true },
        [pscustomobject]@{ Name='cost parent bool'; Raw='{"cost":false}'; Ctx=$true; Cost=$false },
        [pscustomobject]@{ Name='cost parent array'; Raw='{"cost":[]}'; Ctx=$true; Cost=$false }
    )
    foreach ($case in $invalidParentMatrix) {
        $ps = Invoke-Statusline $case.Raw $ctxCostOnConfig @{} '' 5000
        $bash = Invoke-BashStatusline $case.Raw $ctxCostOnConfig @{}
        Check-Run ('PowerShell invalid parent ' + $case.Name) $ps
        Check-Run ('Bash invalid parent ' + $case.Name) $bash
        Check-Exact ('invalid parent differential ' + $case.Name) $ps $bash
        $text = Plain $ps.Stdout
        Check ('invalid parent ctx semantics ' + $case.Name) (($text.Contains('0%') -and $text.Contains((Glyph 0x2191) + '0 ' + (Glyph 0x2193) + '0 cr:0 cw:0')) -eq $case.Ctx)
        Check ('invalid parent cost semantics ' + $case.Name) (($text.Contains('$0.000')) -eq $case.Cost)
        if ($case.Name -eq 'context leaf float text') {
            Check 'non-empty invalid ctx scalar keeps ordinary 0% parsing' ($text.Contains('0%'))
        }
    }

    foreach ($case in @(
        [pscustomobject]@{ Name='false'; Raw='false' },
        [pscustomobject]@{ Name='array'; Raw='[]' },
        [pscustomobject]@{ Name='single-object array'; Raw='[{}]' },
        [pscustomobject]@{ Name='string'; Raw='"root"' }
    )) {
        $ps = Invoke-Statusline $case.Raw $ctxCostOnConfig @{} '' 5000
        $bash = Invoke-BashStatusline $case.Raw $ctxCostOnConfig @{}
        Check-Run ('PowerShell non-object root ' + $case.Name) $ps
        Check-Run ('Bash non-object root ' + $case.Name) $bash
        Check-Exact ('non-object root differential ' + $case.Name) $ps $bash
        Check ('non-object root stays silent ' + $case.Name) ($ps.StdoutBytes.Length -eq 0)
    }

    $malformedCtxCost = '{"context_window":'
    $malformedOnPs = Invoke-Statusline $malformedCtxCost $ctxCostOnConfig @{} '' 5000
    $malformedOnBash = Invoke-BashStatusline $malformedCtxCost $ctxCostOnConfig @{}
    Check-Run 'malformed whole JSON PowerShell always-show' $malformedOnPs
    Check-Run 'malformed whole JSON Bash always-show' $malformedOnBash
    Check-Exact 'malformed whole JSON differential is byte exact' $malformedOnPs $malformedOnBash
    Check 'malformed whole JSON never always-shows' ($malformedOnPs.StdoutBytes.Length -eq 0)

    $costOffConfig = New-Config 'cost-validation-off' @('VL_SEGMENTS=cost','VL_CLOCK=off','VL_NOCOLOR=1','VL_COST_DECIMALS=3')
    $costOnConfig = New-Config 'cost-validation-on' @('VL_SEGMENTS=cost','VL_CLOCK=off','VL_NOCOLOR=1','VL_COST_DECIMALS=3','VL_COST_ALWAYS_SHOW=1')
    $validCostCases = @(
        [pscustomobject]@{ Name='spaced integer'; Literal='" 1 "'; Expected='$1.000'; Zero=$false },
        [pscustomobject]@{ Name='explicit plus'; Literal='"+1"'; Expected='$1.000'; Zero=$false },
        [pscustomobject]@{ Name='leading decimal'; Literal='".5"'; Expected='$0.500'; Zero=$false },
        [pscustomobject]@{ Name='trailing decimal'; Literal='"1."'; Expected='$1.000'; Zero=$false },
        [pscustomobject]@{ Name='leading zero integer'; Literal='"01"'; Expected='$1.000'; Zero=$false },
        [pscustomobject]@{ Name='positive exponent'; Literal='"1e+2"'; Expected='$100.000'; Zero=$false },
        [pscustomobject]@{ Name='exact maximum'; Literal='"1000000000"'; Expected='$1000000000.000'; Zero=$false },
        [pscustomobject]@{ Name='exponent-equivalent maximum'; Literal='"0.1e10"'; Expected='$1000000000.000'; Zero=$false },
        [pscustomobject]@{ Name='minimum normalized exponent'; Literal='"0.000000000000001e-308"'; Expected='$0.000'; Zero=$false },
        [pscustomobject]@{ Name='string negative zero'; Literal='"-0"'; Zero=$true },
        [pscustomobject]@{ Name='string negative decimal zero'; Literal='"-0.0"'; Zero=$true },
        [pscustomobject]@{ Name='string negative exponent zero'; Literal='"-0e10"'; Zero=$true },
        [pscustomobject]@{ Name='number negative zero'; Literal='-0'; Zero=$true },
        [pscustomobject]@{ Name='number negative decimal zero'; Literal='-0.0'; Zero=$true },
        [pscustomobject]@{ Name='number negative exponent zero'; Literal='-0e10'; Zero=$true },
        [pscustomobject]@{ Name='large exponent zero'; Literal='"0e308"'; Zero=$true },
        [pscustomobject]@{ Name='128-character zero'; Literal=('"' + (('0' * 128) -join '') + '"'); Zero=$true }
    )
    foreach ($case in $validCostCases) {
        $raw = '{"cost":{"total_cost_usd":' + $case.Literal + '}}'
        $offPs = Invoke-Statusline $raw $costOffConfig @{} '' 5000
        $offBash = Invoke-BashStatusline $raw $costOffConfig @{}
        $onPs = Invoke-Statusline $raw $costOnConfig @{} '' 5000
        $onBash = Invoke-BashStatusline $raw $costOnConfig @{}
        Check-Run ('PowerShell valid cost ' + $case.Name) $offPs
        Check-Run ('Bash valid cost ' + $case.Name) $offBash
        Check-Run ('PowerShell valid cost always-show ' + $case.Name) $onPs
        Check-Run ('Bash valid cost always-show ' + $case.Name) $onBash
        Check-Exact ('valid cost differential ' + $case.Name) $offPs $offBash
        Check-Exact ('valid cost always-show differential ' + $case.Name) $onPs $onBash
        if ($case.Zero) {
            Check ('valid zero off suppresses ' + $case.Name) ($offPs.StdoutBytes.Length -eq 0)
            Check ('valid zero on formats positive zero ' + $case.Name) ((Plain $onPs.Stdout).Contains('$0.000'))
        } else {
            Check ('valid nonzero off formats expected value ' + $case.Name) ((Plain $offPs.Stdout).Contains($case.Expected))
            Check ('valid nonzero on formats expected value ' + $case.Name) ((Plain $onPs.Stdout).Contains($case.Expected))
        }
    }

    $invalidCostLiterals = @(
        [pscustomobject]@{ Name='bool'; Literal='false' },
        [pscustomobject]@{ Name='array'; Literal='[]' },
        [pscustomobject]@{ Name='object'; Literal='{}' },
        [pscustomobject]@{ Name='whitespace'; Literal='" "' },
        [pscustomobject]@{ Name='negative'; Literal='-1' },
        [pscustomobject]@{ Name='negative-underflow'; Literal='"-0.00000000000000000001e-308"' },
        [pscustomobject]@{ Name='positive-underflow'; Literal='"0.00000000000000000001e-308"' },
        [pscustomobject]@{ Name='nan'; Literal='"NaN"' },
        [pscustomobject]@{ Name='infinity'; Literal='"Infinity"' },
        [pscustomobject]@{ Name='exponent-overflow-string'; Literal='"1e999"' },
        [pscustomobject]@{ Name='exponent-overflow-number'; Literal='1e999' },
        [pscustomobject]@{ Name='fraction-above-range'; Literal='"1000000000.000000001"' },
        [pscustomobject]@{ Name='exponent-fraction-above-range'; Literal='"0.10000000001e10"' },
        [pscustomobject]@{ Name='range'; Literal='1000000001' },
        [pscustomobject]@{ Name='hex'; Literal='"0x10"' },
        [pscustomobject]@{ Name='partial'; Literal='"1x"' },
        [pscustomobject]@{ Name='spaced'; Literal='"1 2"' },
        [pscustomobject]@{ Name='exponent-cap'; Literal='"0e309"' },
        [pscustomobject]@{ Name='negative-exponent-cap'; Literal='"1e-323"' },
        [pscustomobject]@{ Name='length-over'; Literal=('"' + (('0' * 129) -join '') + '"') }
    )
    foreach ($case in $invalidCostLiterals) {
        $raw = '{"cost":{"total_cost_usd":' + $case.Literal + '}}'
        $offPs = Invoke-Statusline $raw $costOffConfig @{} '' 5000
        $offBash = Invoke-BashStatusline $raw $costOffConfig @{}
        $onPs = Invoke-Statusline $raw $costOnConfig @{} '' 5000
        $onBash = Invoke-BashStatusline $raw $costOnConfig @{}
        Check-Run ('PowerShell invalid cost ' + $case.Name) $offPs
        Check-Run ('Bash invalid cost ' + $case.Name) $offBash
        Check-Run ('PowerShell invalid cost always-show ' + $case.Name) $onPs
        Check-Run ('Bash invalid cost always-show ' + $case.Name) $onBash
        Check-Exact ('invalid cost differential ' + $case.Name) $offPs $offBash
        Check-Exact ('invalid cost always-show differential ' + $case.Name) $onPs $onBash
        Check ('invalid cost off is silent ' + $case.Name) ($offPs.StdoutBytes.Length -eq 0)
        Check ('invalid cost always-show is silent ' + $case.Name) ($onPs.StdoutBytes.Length -eq 0)
    }

    $largeTokens = Clone-Object $basePayload
    $largeTokens.context_window.total_input_tokens = '9999999999999999'
    $largeTokenConfig = New-Config 'large-token-format' @('VL_SEGMENTS=ctx','VL_CLOCK=off')
    $largeTokenPs = Invoke-Statusline (Json $largeTokens) $largeTokenConfig @{} '' 5000
    $largeTokenBash = Invoke-BashStatusline (Json $largeTokens) $largeTokenConfig @{}
    Check-Run 'large main token abbreviation' $largeTokenPs
    Check-Run 'large main token abbreviation Bash reference' $largeTokenBash
    Check-Exact 'large main token abbreviation remains byte exact' $largeTokenPs $largeTokenBash
    Check 'large main token abbreviation uses integer quotient' ((Plain $largeTokenPs.Stdout).Contains('9999999999.9M'))

    $dirConfig = New-Config 'dir-only' @('VL_SEGMENTS=dir','VL_CLOCK=off','VL_PATH_DEPTH=4')
    foreach ($case in @(
        [pscustomobject]@{ Name='Unix root'; Path='/'; Expected=' / ' },
        [pscustomobject]@{ Name='drive root'; Path='C:/'; Expected=' C:/ ' },
        [pscustomobject]@{ Name='deep drive'; Path='C:/one/two/three/four'; Expected=' C:/one/' + (Glyph 0x2026) + '/four ' },
        [pscustomobject]@{ Name='UNC root'; Path='//server/share/'; Expected=' //server/share ' },
        [pscustomobject]@{ Name='deep UNC'; Path='//server/share/one/two/three'; Expected=' //server/share/' + (Glyph 0x2026) + '/three ' }
    )) {
        $payload = New-Payload $case.Path
        $run = Invoke-Statusline (Json $payload) $dirConfig @{} '' 5000
        Check-Run $case.Name $run
        Check "$($case.Name) path semantics" ((Plain $run.Stdout).Contains($case.Expected))
    }

    $durationConfig = New-Config 'duration-main' @('VL_SEGMENTS=duration','VL_CLOCK=off')
    $durationRun = Invoke-Statusline (Json $basePayload) $durationConfig @{} '' 5000
    Check 'main duration omits seconds once minutes render' ((Plain $durationRun.Stdout).Contains('1h30m') -and -not (Plain $durationRun.Stdout).Contains('1h30m54s'))

    $midpointConfig = New-Config 'percent-midpoint' @('VL_SEGMENTS=ctx\ limit5h\ limit7d','VL_CLOCK=off')
    foreach ($raw in @('61.5','62.5')) {
        $payload = Clone-Object $basePayload
        $value = [double]::Parse($raw, $Invariant)
        $payload.context_window.used_percentage = $value
        $payload.rate_limits.five_hour.used_percentage = $value
        $payload.rate_limits.seven_day.used_percentage = $value
        $psRun = Invoke-Statusline (Json $payload) $midpointConfig @{} '' 5000
        $bashRun = Invoke-BashStatusline (Json $payload) $midpointConfig @{}
        Check-Run "PowerShell percentage midpoint $raw" $psRun
        Check-Run "Bash percentage midpoint $raw" $bashRun
        Check-Exact "percentage midpoint $raw differential is byte exact" $psRun $bashRun
    }

    foreach ($raw in @('-5','NaN','Infinity','1e999','999999999999999999999999999999')) {
        $payload = Clone-Object $basePayload
        $payload.context_window.used_percentage = $raw
        $payload.rate_limits.five_hour.used_percentage = $raw
        $payload.cost.total_cost_usd = $raw
        $payload.cost.total_duration_ms = $raw
        $payload.cost.total_lines_added = $raw
        $numericConfig = New-Config ('numeric-' + [Math]::Abs($raw.GetHashCode())) @(
            'VL_SEGMENTS=ctx\ limit5h\ cost\ duration\ lines',
            'VL_CLOCK=off',
            'VL_BAR_WIDTH=999999999999999999999',
            'VL_COST_DECIMALS=-1',
            'VL_WARN_PCT=NaN',
            'VL_HOT_PCT=Infinity',
            'VL_BG_CTX=999'
        )
        $run = Invoke-Statusline (Json $payload) $numericConfig @{} '' 5000
        Check-Run "bounded numeric $raw" $run
        Check "bounded numeric $raw output is finite" ($run.StdoutBytes.Length -lt 4096 -and -not $run.Stdout.Contains('NaN') -and -not $run.Stdout.Contains('Infinity'))
        Check "bounded numeric $raw invalid color falls back" ($run.Stdout.Contains('48;5;238m'))
    }

    $absentConfig = New-Config 'absent-executables' @('VL_SEGMENTS=git\ node\ python\ model','VL_CLOCK=off','VL_RUNTIME_PROBE=1')
    $absentPayload = New-Payload (Forward-Path (Join-Path $TempRoot 'no-pin-dir'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $TempRoot 'no-pin-dir'))
    $emptyPath = Join-Path $TempRoot 'empty-path'
    [void][System.IO.Directory]::CreateDirectory($emptyPath)
    $absentRun = Invoke-Statusline (Json $absentPayload) $absentConfig @{ PATH=$emptyPath } '' 5000
    Check-Run 'absent Git Node Python executables' $absentRun
    Check 'absent executables suppress only dependent segments' ((Plain $absentRun.Stdout).Contains('MODEL_SENTINEL') -and -not (Plain $absentRun.Stdout).Contains('20.11.1') -and -not (Plain $absentRun.Stdout).Contains('3.12.2'))

    $pythonEnvConfig = New-Config 'python-env-cwd-gate' @('VL_SEGMENTS=python','VL_CLOCK=off')
    foreach ($case in @(
        [pscustomobject]@{ Name='virtualenv'; Environment=@{ VIRTUAL_ENV='C:/venvs/demo' } },
        [pscustomobject]@{ Name='conda'; Environment=@{ CONDA_DEFAULT_ENV='demo' } }
    )) {
        $emptyPs = Invoke-Statusline '{}' $pythonEnvConfig $case.Environment '' 5000
        $emptyBash = Invoke-BashStatusline '{}' $pythonEnvConfig $case.Environment
        Check-Run "PowerShell empty-cwd $($case.Name)" $emptyPs
        Check-Run "Bash empty-cwd $($case.Name)" $emptyBash
        Check-Exact "empty-cwd $($case.Name) differential is byte exact" $emptyPs $emptyBash
        Check "empty-cwd $($case.Name) suppresses python" ($emptyPs.StdoutBytes.Length -eq 0)

        $cwdPs = Invoke-Statusline (Json $basePayload) $pythonEnvConfig $case.Environment '' 5000
        $cwdBash = Invoke-BashStatusline (Json $basePayload) $pythonEnvConfig $case.Environment
        Check-Run "PowerShell cwd $($case.Name)" $cwdPs
        Check-Run "Bash cwd $($case.Name)" $cwdBash
        Check-Exact "cwd $($case.Name) differential is byte exact" $cwdPs $cwdBash
        Check "cwd $($case.Name) renders env label" ((Plain $cwdPs.Stdout).Contains('demo'))
    }

    $controlPayload = New-Payload ''
    $controlPayload.model.display_name = 'Claude A' + [char]0 + 'B' + [char]27 + '[2J' + 'C' + [char]10 + 'D' + [char]13 + 'E' + [char]0x7F + 'F' + [char]0x85 + 'G'
    $controlConfig = New-Config 'control-scrub' @('VL_SEGMENTS=model','VL_CLOCK=off')
    $controlRun = Invoke-Statusline (Json $controlPayload) $controlConfig @{} '' 5000
    Check-Run 'main payload control scrub' $controlRun
    $controlPlain = Plain $controlRun.Stdout
    Check 'main payload controls are removed from visible text' ($controlPlain.Contains('AB[2JCDEFG'))
    $maliciousAnsi = [byte[]]@(27,91,50,74)
    $hasMalicious = $false
    for ($i=0; $i -le $controlRun.StdoutBytes.Length - $maliciousAnsi.Length; $i++) {
        $same = $true
        for ($j=0; $j -lt $maliciousAnsi.Length; $j++) { if ($controlRun.StdoutBytes[$i+$j] -ne $maliciousAnsi[$j]) { $same=$false; break } }
        if ($same) { $hasMalicious=$true; break }
    }
    Check 'payload ESC cannot create terminal ANSI' (-not $hasMalicious)
    Check 'renderer-generated ANSI remains present' ($controlRun.Stdout.Contains(([string][char]27 + '[48;5;173m')))
    Check 'payload CR and C1 bytes are absent' (-not ($controlRun.StdoutBytes -contains [byte]13) -and -not $controlRun.Stdout.Contains([string][char]0x85))
    $controlBash = Invoke-BashStatusline (Json $controlPayload) $controlConfig @{}
    Check-Run 'Bash main payload control scrub' $controlBash
    Check 'Bash and PowerShell scrub have the same observable output' ($controlRun.Stdout -eq $controlBash.Stdout)

    $codepagePayload = New-Payload ''
    $codepagePayload.model.display_name = 'Claude UTF8-' + (Glyph 0x96EA)
    $codepageConfig = New-Config 'codepage' @('VL_SEGMENTS=model','VL_CLOCK=off')
    $command = '[Console]::OutputEncoding=[Text.Encoding]::GetEncoding(437); & ''' + $Script + ''''
    $cpArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + $command.Replace('"','\"') + '"'
    $codepageRun = Invoke-CapturedProcess $PowerShellExe $cpArgs (Json $codepagePayload) (Runtime-Environment $codepageConfig @{}) $Repo 5000
    Check-Run 'codepage 437 raw I/O' $codepageRun
    Check 'stdout is UTF-8 without BOM' ($codepageRun.StdoutBytes.Length -ge 3 -and -not ($codepageRun.StdoutBytes[0] -eq 0xEF -and $codepageRun.StdoutBytes[1] -eq 0xBB -and $codepageRun.StdoutBytes[2] -eq 0xBF) -and $codepageRun.Stdout.Contains((Glyph 0x96EA)))
    Check 'stdout uses LF without CR' (-not ($codepageRun.StdoutBytes -contains [byte]13) -and $codepageRun.StdoutBytes[$codepageRun.StdoutBytes.Length - 1] -eq 10)

    # WIN-02 mutable TSV state, estimator parity, and path boundaries.
    $stateRoot = Join-Path $TempRoot 'win02-state'
    [void][IO.Directory]::CreateDirectory($stateRoot)
    $fixedNow = 1000000L
    $reset5 = 1015900L
    $reset7 = 1345600L
    $statePayload = Clone-Object $basePayload
    $statePayload.rate_limits.five_hour.used_percentage = '41.2'
    $statePayload.rate_limits.five_hour.resets_at = [string]$reset5
    $statePayload.rate_limits.seven_day.used_percentage = '30'
    $statePayload.rate_limits.seven_day.resets_at = [string]$reset7
    $stateEnvWrite = @{ CORALLINE_NO_SAMPLE=$null; CORALLINE_TEST_NOW=[string]$fixedNow }
    $stateEnvRead = @{ CORALLINE_NO_SAMPLE='1'; CORALLINE_TEST_NOW=[string]$fixedNow }

    $mathDump = Join-Path $stateRoot 'math.txt'
    $mathArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script:StateScript + '"'
    $mathRun = Invoke-CapturedProcess $PowerShellExe $mathArgs '' (Runtime-Environment '' @{ CORALLINE_TEST_NOW=[string]$fixedNow; CORALLINE_TEST_MATH_DUMP=$mathDump }) $Repo 10000
    Check-Run 'WIN-02 PowerShell exact rational helper vectors' $mathRun
    Check 'WIN-02 exact midpoint/rate/carry/max arithmetic' ([IO.File]::ReadAllText($mathDump, $StrictUtf8) -ceq '2|4|1|2|0.3333333333|1.0000000000|8639914')

    function New-StateConfig([string]$Name, [string]$Root, [string]$Segments, [bool]$Sync) {
        [void][IO.Directory]::CreateDirectory($Root)
        $burn = Forward-Path (Join-Path $Root 'burn.tsv')
        $limit5 = Forward-Path (Join-Path $Root 'limit5.tsv')
        $limit7 = Forward-Path (Join-Path $Root 'limit7.tsv')
        $lines = @(
            ('VL_SEGMENTS=' + (Quote-FromConfigure $Segments)),
            'VL_CLOCK=off',
            ("BURN_FILE='$burn'"),
            ("RL5H_FILE='$limit5'"),
            ("RL7D_FILE='$limit7'")
        )
        if ($Sync) { $lines += 'VL_LIMIT_SYNC=1' }
        return New-Config $Name $lines
    }

    $sequentialRoot = Join-Path $stateRoot 'sequential'
    $sequentialConfig = New-StateConfig 'win02-sequential' $sequentialRoot 'burn limit5h limit7d' $true
    $psWrite = Invoke-Statusline (Json $statePayload) $sequentialConfig $stateEnvWrite '' 10000
    Check-Run 'WIN-02 PowerShell first writer' $psWrite
    $burnPath = Join-Path $sequentialRoot 'burn.tsv'
    $burnStore = Join-Path $sequentialRoot 'burn.d'
    $limit5Store = Join-Path $sequentialRoot 'limit5.d'
    $limit7Store = Join-Path $sequentialRoot 'limit7.d'
    $burnRows = [IO.File]::ReadAllLines($burnPath, $StrictUtf8)
    Check 'WIN-02 PowerShell appends canonical burn TSV row' ($burnRows.Count -eq 1 -and $burnRows[0] -ceq "1000000`t41.200`t1015900")
    Check 'WIN-02 PowerShell ignores absent burn marker store' (-not [IO.Directory]::Exists($burnStore))
    Check 'WIN-02 PowerShell canonical 5h directory' ([IO.Directory]::Exists((Join-Path $limit5Store '0001015900_041.200')))
    Check 'WIN-02 PowerShell canonical 7d directory' ([IO.Directory]::Exists((Join-Path $limit7Store '0001345600_030.000')))

    $bashRead = Invoke-BashStatusline (Json $statePayload) $sequentialConfig $stateEnvRead
    Check-Run 'WIN-02 Bash reads PowerShell state' $bashRead
    Check-Exact 'WIN-02 Bash reader matches PowerShell fixed-pill output' $bashRead $psWrite
    Remove-Item -LiteralPath $burnPath,$limit5Store,$limit7Store -Recurse -Force -ErrorAction SilentlyContinue
    $bashWrite = Invoke-BashStatusline (Json $statePayload) $sequentialConfig $stateEnvWrite
    Check-Run 'WIN-02 Bash first writer' $bashWrite
    $burnRows = [IO.File]::ReadAllLines($burnPath, $StrictUtf8)
    Check 'WIN-02 Bash appends canonical burn TSV row' ($burnRows.Count -eq 1 -and $burnRows[0] -ceq "1000000`t41.200`t1015900")
    Check 'WIN-02 Bash leaves absent burn marker store absent' (-not [IO.Directory]::Exists($burnStore))
    $psRead = Invoke-Statusline (Json $statePayload) $sequentialConfig $stateEnvRead '' 10000
    Check-Run 'WIN-02 PowerShell reads Bash state' $psRead
    Check-Exact 'WIN-02 PowerShell reader matches Bash fixed-pill output' $psRead $bashWrite

    # Default store base follows CLAUDE_CONFIG_DIR (two Claude config directories
    # must not share one 5h/7d store). No BURN_FILE/RL*_FILE override is set, so
    # the assertion is on where the renderer's own defaults put the files.
    $baseConfig = New-Config 'win02-store-base' @(('VL_SEGMENTS=' + (Quote-FromConfigure 'limit5h limit7d')),'VL_CLOCK=off','VL_LIMIT_SYNC=1')
    $baseRoot = Join-Path $stateRoot 'store-base'
    foreach ($case in @('redirected','plain')) {
        $caseRoot = Join-Path $baseRoot $case
        $caseHome = Join-Path $caseRoot 'home'
        [void][IO.Directory]::CreateDirectory($caseHome)
        $baseEnv = @{ CORALLINE_NO_SAMPLE=$null; CORALLINE_TEST_NOW=[string]$fixedNow
                      HOME=(Forward-Path $caseHome); USERPROFILE=$caseHome }
        if ($case -eq 'redirected') { $baseEnv.CLAUDE_CONFIG_DIR = Join-Path $caseRoot 'alt' }
        else { $baseEnv.CLAUDE_CONFIG_DIR = $null }
        $baseRun = Invoke-Statusline (Json $statePayload) $baseConfig $baseEnv '' 10000
        Check-Run "WIN-02 PowerShell default store base $case" $baseRun
        $homeStore = Join-Path $caseHome '.claude\coralline\limit-5h.d'
        if ($case -eq 'redirected') {
            Check 'WIN-02 CLAUDE_CONFIG_DIR redirects the default store' ([IO.Directory]::Exists((Join-Path $caseRoot 'alt\coralline\limit-5h.d')))
            Check 'WIN-02 redirected store leaves the HOME store untouched' (-not [IO.Directory]::Exists((Join-Path $caseHome '.claude\coralline')))
        } else {
            Check 'WIN-02 unset CLAUDE_CONFIG_DIR keeps the historical HOME store' ([IO.Directory]::Exists($homeStore))
        }
    }

    # C:\, C:/, and /c/ spellings must resolve to the same physical store.
    $identityRoot = Join-Path $stateRoot 'identity'
    [void][IO.Directory]::CreateDirectory($identityRoot)
    $identityNative = Join-Path $identityRoot 'burn.tsv'
    $identityForward = Forward-Path $identityNative
    $identityMsys = '/' + $identityForward.Substring(0,1).ToLowerInvariant() + $identityForward.Substring(2)
    $identityForms = @($identityNative, $identityForward, $identityMsys)
    for ($i=0; $i -lt $identityForms.Count; $i++) {
        $config = New-Config ("win02-identity-$i") @('VL_SEGMENTS=burn','VL_CLOCK=off',("BURN_FILE='" + $identityForms[$i] + "'"))
        $payload = Clone-Object $statePayload
        $payload.rate_limits.five_hour.used_percentage = [string](10 + $i)
        $identityDump = Join-Path $identityRoot ("state-$i.txt")
        $identityEnv = @{ CORALLINE_NO_SAMPLE=$null; CORALLINE_TEST_NOW=[string]($fixedNow + $i); CORALLINE_TEST_STATE_DUMP=(Forward-Path $identityDump) }
        if ($i -eq 2) { $identityEnv.CORALLINE_TEST_STRICT='1' }
        if (($i % 2) -eq 0) { $run = Invoke-Statusline (Json $payload) $config $identityEnv '' 10000 }
        else { $run = Invoke-BashStatusline (Json $payload) $config $identityEnv }
        Check-Run "WIN-02 path identity writer $i" $run
    }
    $identityRows = [IO.File]::ReadAllLines($identityNative, $StrictUtf8)
    if ($identityRows.Count -ne 3) {
        [Console]::Out.WriteLine('DIAG  WIN-02 identity rows=' + ($identityRows -join '|'))
        foreach ($dump in @(Get-ChildItem -LiteralPath $identityRoot -Filter 'state-*.txt' -File | Sort-Object Name)) { [Console]::Out.WriteLine('DIAG  ' + $dump.Name + '=' + [IO.File]::ReadAllText($dump.FullName, $StrictUtf8)) }
    }
    Check 'WIN-02 C native/forward/MSYS forms share one TSV' ($identityRows.Count -eq 3 -and -not [IO.Directory]::Exists((Join-Path $identityRoot 'burn.d')))

    # Exact decimal vectors are checked through canonical TSV rows in both runtimes.
    $pctVectors = @(
        [pscustomobject]@{Raw='1.2345'; Canon='1.234'; Valid=$true},
        [pscustomobject]@{Raw='1.2355'; Canon='1.236'; Valid=$true},
        [pscustomobject]@{Raw='99.9995'; Canon='100.000'; Valid=$true},
        [pscustomobject]@{Raw='100.000001'; Canon=''; Valid=$false},
        [pscustomobject]@{Raw='-0'; Canon=''; Valid=$false},
        [pscustomobject]@{Raw='1e2'; Canon=''; Valid=$false},
        [pscustomobject]@{Raw='1,2'; Canon=''; Valid=$false}
    )
    for ($i=0; $i -lt $pctVectors.Count; $i++) {
        $vectorRoot = Join-Path $stateRoot ("pct-$i")
        $config = New-StateConfig ("win02-pct-$i") $vectorRoot 'burn' $false
        $payload = Clone-Object $statePayload
        $payload.rate_limits.five_hour.used_percentage = $pctVectors[$i].Raw
        if (($i % 2) -eq 0) { $run = Invoke-Statusline (Json $payload) $config $stateEnvWrite '' 10000 }
        else { $run = Invoke-BashStatusline (Json $payload) $config $stateEnvWrite }
        Check-Run "WIN-02 canonical pct writer $i" $run
        $rows = @()
        $vectorPath = Join-Path $vectorRoot 'burn.tsv'
        if ([IO.File]::Exists($vectorPath)) { $rows = [IO.File]::ReadAllLines($vectorPath, $StrictUtf8) }
        if ($pctVectors[$i].Valid) { Check "WIN-02 canonical pct $($pctVectors[$i].Raw)" ($rows.Count -eq 1 -and $rows[0].Contains("`t$($pctVectors[$i].Canon)`t")) }
        else { Check "WIN-02 rejects pct $($pctVectors[$i].Raw)" ($rows.Count -eq 0) }
    }

    # Store-only estimator vector: exact same-second reduction, rate-derived ETA,
    # reset isolation, and raw fixed-pill output must agree.
    $estimateRoot = Join-Path $stateRoot 'estimate'
    $estimateConfig = New-StateConfig 'win02-estimate' $estimateRoot 'burn' $false
    $estimatePath = Join-Path $estimateRoot 'burn.tsv'
    Write-Utf8 $estimatePath "999640`t006.000`t1015900`n999700`t007.000`t1015900`n999700`t006.500`t1015900`n999940`t008.000`t1015900`n1000000`t008.000`t1015900`n999900`t051.000`t1010000`n"
    $estimatePayload = Clone-Object $statePayload
    $estimatePayload.rate_limits.five_hour.used_percentage = '8'
    $estimatePsDump = Join-Path $estimateRoot 'ps-state.json'
    $estimateBashDump = Join-Path $estimateRoot 'bash-state.txt'
    $estimatePsEnv = @{ CORALLINE_NO_SAMPLE='1'; CORALLINE_TEST_NOW=[string]$fixedNow; CORALLINE_TEST_STATE_DUMP=$estimatePsDump }
    $estimateBashEnv = @{ CORALLINE_NO_SAMPLE='1'; CORALLINE_TEST_NOW=[string]$fixedNow; CORALLINE_TEST_STATE_DUMP=(Forward-Path $estimateBashDump) }
    $estimatePs = Invoke-Statusline (Json $estimatePayload) $estimateConfig $estimatePsEnv '' 10000
    $estimateBash = Invoke-BashStatusline (Json $estimatePayload) $estimateConfig $estimateBashEnv
    Check-Run 'WIN-02 PowerShell estimator vector' $estimatePs
    Check-Run 'WIN-02 Bash estimator vector' $estimateBash
    $estimatePsState = [IO.File]::ReadAllText($estimatePsDump, $StrictUtf8) | ConvertFrom-Json
    $estimateBashState = [IO.File]::ReadAllText($estimateBashDump, $StrictUtf8).Trim()
    Check 'WIN-02 PowerShell exact estimator semantics' ($estimatePsState.FiveState -eq 'active' -and [string]$estimatePsState.FiveEta -eq '22080' -and $estimatePsState.FiveRate -eq '0.0041666667' -and [string]$estimatePsState.FiveTtr -eq '15900' -and $estimatePsState.BurnLabel -eq '5h')
    Check 'WIN-02 same-second maximum preserves synthetic slope' ($estimatePsState.FiveEta -eq 22080 -and $estimatePsState.FiveRate -eq '0.0041666667')
    Check 'WIN-02 Bash exact estimator semantics' ($estimateBashState.Contains('FiveState=active FiveEta=22080 FiveRate=0.0041666667 FiveTtr=15900') -and $estimateBashState.Contains('BurnState=active BurnLabel=5h BurnEta=22080'))
    if (-not ($estimatePsState.FiveState -eq 'active')) { [Console]::Out.WriteLine('DIAG  WIN-02 PowerShell state=' + ([IO.File]::ReadAllText($estimatePsDump, $StrictUtf8))) }
    Check-Exact 'WIN-02 estimator fixed-pill differential' $estimatePs $estimateBash
    Check 'WIN-02 estimator exact ETA visible' ((Plain $estimatePs.Stdout).Contains((Glyph 0x2197) + ' ' + (Glyph 0x2713)))

    # 7d rational vectors straddle an exact .5 ETA without binary floating point.
    # The exact midpoint has an even quotient and stays down; one milli-percent
    # below/above it lands on opposite sides. Both runtimes expose the same state.
    foreach ($vector in @(
        [pscustomobject]@{Pct='39.999'; Eta='5'; Rate=''},
        [pscustomobject]@{Pct='40'; Eta='4'; Rate='13.3333333333'},
        [pscustomobject]@{Pct='40.001'; Eta='4'; Rate=''}
    )) {
        $rationalRoot = Join-Path $stateRoot ('rational-' + $vector.Pct.Replace('.','-'))
        $rationalConfig = New-StateConfig ('win02-rational-' + $vector.Pct.Replace('.','-')) $rationalRoot 'burn' $false
        $rationalPayload = Clone-Object $statePayload
        $rationalPayload.rate_limits.five_hour.used_percentage = $null
        $rationalPayload.rate_limits.five_hour.resets_at = $null
        $rationalPayload.rate_limits.seven_day.used_percentage = $vector.Pct
        $rationalPayload.rate_limits.seven_day.resets_at = [string]($fixedNow + 604797L)
        $psDump = Join-Path $rationalRoot 'ps.json'
        $bashDump = Join-Path $rationalRoot 'bash.txt'
        $psEnv = @{ CORALLINE_NO_SAMPLE='1'; CORALLINE_TEST_NOW=[string]$fixedNow; CORALLINE_TEST_STATE_DUMP=$psDump }
        $bashEnv = @{ CORALLINE_NO_SAMPLE='1'; CORALLINE_TEST_NOW=[string]$fixedNow; CORALLINE_TEST_STATE_DUMP=(Forward-Path $bashDump) }
        $psRun = Invoke-Statusline (Json $rationalPayload) $rationalConfig $psEnv '' 10000
        $bashRun = Invoke-BashStatusline (Json $rationalPayload) $rationalConfig $bashEnv
        Check-Run ('WIN-02 PowerShell rational pct ' + $vector.Pct) $psRun
        Check-Run ('WIN-02 Bash rational pct ' + $vector.Pct) $bashRun
        Check-Exact ('WIN-02 rational fixed-pill differential ' + $vector.Pct) $psRun $bashRun
        $psState = [IO.File]::ReadAllText($psDump, $StrictUtf8) | ConvertFrom-Json
        $bashState = [IO.File]::ReadAllText($bashDump, $StrictUtf8).Trim()
        Check ('WIN-02 rational ETA ' + $vector.Pct) ([string]$psState.SevenEta -eq $vector.Eta -and $bashState.Contains('SevenEta=' + $vector.Eta + ' '))
        if (-not [string]::IsNullOrEmpty($vector.Rate)) { Check 'WIN-02 rational non-divisible 7d rate' ($psState.SevenRate -eq $vector.Rate -and $bashState.Contains('SevenRate=' + $vector.Rate + ' ')) }
        Check ('WIN-02 rational no-sample burn TSV absent ' + $vector.Pct) (-not [IO.File]::Exists((Join-Path $rationalRoot 'burn.tsv')))
    }

    # Deterministic controls distinguish unchanged usage, truly idle history, and
    # reset rollover. No live Claude quota movement is used as correctness evidence.
    foreach ($control in @(
        [pscustomobject]@{
            Name='unchanged'; Expected='warming'; Pct='10';
            Entries=@(
                "999500`t010.000`t1015900",
                "999700`t010.000`t1015900",
                "999900`t010.000`t1015900"
            )
        },
        [pscustomobject]@{
            Name='idle'; Expected='idle'; Pct='6';
            Entries=@(
                "999000`t005.000`t1015900",
                "999100`t006.000`t1015900",
                "999900`t006.000`t1015900"
            )
        },
        [pscustomobject]@{
            Name='reset-rollover'; Expected='warming'; Pct='2';
            Entries=@(
                "999500`t005.000`t1010000",
                "999700`t006.000`t1010000",
                "999900`t007.000`t1010000",
                "999950`t002.000`t1015900"
            )
        }
    )) {
        $controlRoot = Join-Path $stateRoot ('estimator-' + $control.Name)
        $controlConfig = New-StateConfig ('win02-estimator-' + $control.Name) $controlRoot 'burn' $false
        $controlPath = Join-Path $controlRoot 'burn.tsv'
        Write-Utf8 $controlPath (($control.Entries -join "`n") + "`n")
        $controlPayload = Clone-Object $statePayload
        $controlPayload.rate_limits.five_hour.used_percentage = $control.Pct
        $controlPayload.rate_limits.seven_day.used_percentage = $null
        $controlPayload.rate_limits.seven_day.resets_at = $null
        $psDump = Join-Path $controlRoot 'ps.json'
        $bashDump = Join-Path $controlRoot 'bash.txt'
        $psEnv = @{ CORALLINE_NO_SAMPLE='1'; CORALLINE_TEST_NOW=[string]$fixedNow; CORALLINE_TEST_STATE_DUMP=$psDump }
        $bashEnv = @{ CORALLINE_NO_SAMPLE='1'; CORALLINE_TEST_NOW=[string]$fixedNow; CORALLINE_TEST_STATE_DUMP=(Forward-Path $bashDump) }
        $psRun = Invoke-Statusline (Json $controlPayload) $controlConfig $psEnv '' 10000
        $bashRun = Invoke-BashStatusline (Json $controlPayload) $controlConfig $bashEnv
        Check-Run ('WIN-02 PowerShell estimator control ' + $control.Name) $psRun
        Check-Run ('WIN-02 Bash estimator control ' + $control.Name) $bashRun
        Check-Exact ('WIN-02 estimator control differential ' + $control.Name) $psRun $bashRun
        $psState = [IO.File]::ReadAllText($psDump, $StrictUtf8) | ConvertFrom-Json
        $bashState = [IO.File]::ReadAllText($bashDump, $StrictUtf8).Trim()
        Check ('WIN-02 deterministic estimator state ' + $control.Name) ($psState.FiveState -eq $control.Expected -and $bashState.Contains('FiveState=' + $control.Expected + ' '))
    }

    # CORALLINE_NO_SAMPLE preserves the mutable TSV and any pre-existing marker tree.
    $readonlyRoot = Join-Path $stateRoot 'readonly'
    $readonlyConfig = New-StateConfig 'win02-readonly' $readonlyRoot 'burn limit5h limit7d' $true
    [void][IO.Directory]::CreateDirectory((Join-Path $readonlyRoot 'burn.d'))
    [void][IO.Directory]::CreateDirectory((Join-Path $readonlyRoot 'limit5.d\9999999999_099.000'))
    [void][IO.Directory]::CreateDirectory((Join-Path $readonlyRoot 'limit7.d\9999999999_099.000'))
    [IO.File]::WriteAllBytes((Join-Path $readonlyRoot 'burn.d\b_253402300799_000001000000_099.000_0000'), [byte[]]@())
    [IO.File]::WriteAllText((Join-Path $readonlyRoot 'burn.d\malformed'), 'x', $Utf8NoBom)
    Write-Utf8 (Join-Path $readonlyRoot 'burn.tsv') "1000000`t41.2`t1015900`n"
    [void](Snapshot-StateTree $readonlyRoot)
    $readonlyBefore = Snapshot-StateTree $readonlyRoot
    $readonlyPs = Invoke-Statusline (Json $statePayload) $readonlyConfig $stateEnvRead '' 10000
    $readonlyBash = Invoke-BashStatusline (Json $statePayload) $readonlyConfig $stateEnvRead
    Check-Run 'WIN-02 PowerShell no-sample' $readonlyPs
    Check-Run 'WIN-02 Bash no-sample' $readonlyBash
    Check 'WIN-02 no-sample tree metadata unchanged' ((Snapshot-StateTree $readonlyRoot) -ceq $readonlyBefore)
    $missingReadonlyRoot = Join-Path $stateRoot 'readonly-missing'
    $missingReadonlyConfig = New-StateConfig 'win02-readonly-missing' $missingReadonlyRoot 'burn limit5h limit7d' $true
    [void](Invoke-Statusline (Json $statePayload) $missingReadonlyConfig $stateEnvRead '' 10000)
    [void](Invoke-BashStatusline (Json $statePayload) $missingReadonlyConfig $stateEnvRead)
    Check 'WIN-02 no-sample leaves missing roots absent' (-not [IO.File]::Exists((Join-Path $missingReadonlyRoot 'burn.tsv')) -and -not [IO.Directory]::Exists((Join-Path $missingReadonlyRoot 'limit5.d')))

    # A valid marker directory is ignored and a bounded TSV is trimmed/healed.
    $mutableRoot = Join-Path $stateRoot 'mutable'
    $mutableConfig = New-StateConfig 'win02-mutable' $mutableRoot 'burn' $false
    $mutablePath = Join-Path $mutableRoot 'burn.tsv'
    $mutableMarker = Join-Path $mutableRoot 'burn.d'
    [void][IO.Directory]::CreateDirectory($mutableMarker)
    $markerFile = Join-Path $mutableMarker 'keep'
    Write-Utf8 $markerFile 'marker'
    $mutableBuilder = New-Object Text.StringBuilder
    [void]$mutableBuilder.Append("999998`t010.000`t999997`n")
    for ($i=0; $i -lt 1500; $i++) {
        [void]$mutableBuilder.Append((($fixedNow - 1500L + $i).ToString($Invariant) + "`t010.000`t1015900`n"))
    }
    Write-Utf8 $mutablePath $mutableBuilder.ToString()
    $markerBefore = Snapshot-StateTree $mutableMarker
    $mutableRun = Invoke-Statusline (Json $statePayload) $mutableConfig $stateEnvWrite '' 30000
    Check-Run 'WIN-02 mutable burn trim/heal' $mutableRun
    $mutableRows = [IO.File]::ReadAllLines($mutablePath, $StrictUtf8)
    Check 'WIN-02 mutable burn trims to BURN_TRIM and heals stale row' ($mutableRows.Count -eq 1500 -and -not ($mutableRows -contains "999998`t010.000`t999997"))
    Check 'WIN-02 mutable burn leaves marker tree byte exact' ((Snapshot-StateTree $mutableMarker) -ceq $markerBefore)
    # Trim keeps the tail, in order. A row count alone would pass on rewritten,
    # reordered or partially written content.
    $mutableExpected = New-Object 'System.Collections.Generic.List[string]'
    for ($i = $mutableRows.Count - 1; $i -ge 0; $i--) { [void]$mutableExpected.Add($mutableRows[$i]) }
    $mutableSorted = $true
    for ($i = 1; $i -lt $mutableRows.Count; $i++) {
        $prev = [long](($mutableRows[$i - 1]).Split(@("`t"), [StringSplitOptions]::None)[0])
        $cur = [long](($mutableRows[$i]).Split(@("`t"), [StringSplitOptions]::None)[0])
        if ($cur -lt $prev) { $mutableSorted = $false; break }
    }
    Check 'WIN-02 mutable burn retains rows in sample order' $mutableSorted
    $mutableFields = $true
    foreach ($line in $mutableRows) {
        if (($line.Split(@("`t"), [StringSplitOptions]::None)).Length -ne 3) { $mutableFields = $false; break }
    }
    Check 'WIN-02 mutable burn writes no partial record' $mutableFields
    # The rewrite goes through a temp and a backup; neither may survive it.
    $mutableParent = [IO.Path]::GetDirectoryName($mutablePath)
    $mutableResidue = @(Get-ChildItem -LiteralPath $mutableParent -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '.burn.tmp.*' -or $_.Name -like '.burn.bak.*' })
    Check 'WIN-02 mutable burn leaves no temp or backup residue' ($mutableResidue.Count -eq 0)

    # A render that is killed never reaches its finally block, so its temp survives
    # and nothing used to retire it. The next mutating render sweeps what is
    # unambiguously ours and unambiguously dead: the complete generated shape, a
    # regular file, older than the store, and older than an hour. The age floor is
    # what a second burn store sharing this directory relies on, since the name
    # carries no store identity and a render lives well under a second.
    $sweepRoot = Join-Path $stateRoot 'tmpsweep'
    $sweepConfig = New-StateConfig 'win02-tmpsweep' $sweepRoot 'burn' $false
    $sweepPath = Join-Path $sweepRoot 'burn.tsv'
    Write-Utf8 $sweepPath (($fixedNow - 100L).ToString($Invariant) + "`t010.000`t1015900`n")
    $sweepOrphans = @('.burn.tmp.4242.0123456789abcdef0123456789abcdef',
                      '.burn.bak.4242.fedcba9876543210fedcba9876543210')
    # Shape keep cases: a user file under the prefix, and a truncated suffix.
    $sweepKeep = @('.burn.tmp.user-backup', '.burn.tmp.4242.short',
                   '.burn.other.4242', 'burn.tmp.4242')
    foreach ($leaf in ($sweepOrphans + $sweepKeep)) { Write-Utf8 (Join-Path $sweepRoot $leaf) 'x' }
    $sweepStamp = [IO.File]::GetLastWriteTimeUtc($sweepPath)
    foreach ($leaf in ($sweepOrphans + $sweepKeep)) {
        [IO.File]::SetLastWriteTimeUtc((Join-Path $sweepRoot $leaf), $sweepStamp.AddHours(-2))
    }
    # Correctly shaped and older than the store, but well inside the hour, which is
    # what a live temporary belonging to another store in this directory looks like.
    $sweepRecent = Join-Path $sweepRoot '.burn.tmp.4244.99887766554433221100ffeeddccbbaa'
    Write-Utf8 $sweepRecent 'x'
    [IO.File]::SetLastWriteTimeUtc($sweepRecent, $sweepStamp.AddMinutes(-5))
    $sweepLive = Join-Path $sweepRoot '.burn.tmp.4243.00112233445566778899aabbccddeeff'
    Write-Utf8 $sweepLive 'x'
    [IO.File]::SetLastWriteTimeUtc($sweepLive, $sweepStamp.AddSeconds(30))
    $sweepRun = Invoke-Statusline (Json $statePayload) $sweepConfig $stateEnvWrite '' 10000
    Check-Run 'WIN-02 orphaned temp sweep' $sweepRun
    foreach ($leaf in $sweepOrphans) {
        Check ('WIN-02 sweep removes ' + $leaf) (-not [IO.File]::Exists((Join-Path $sweepRoot $leaf)))
    }
    foreach ($leaf in $sweepKeep) {
        Check ('WIN-02 sweep keeps ' + $leaf) ([IO.File]::Exists((Join-Path $sweepRoot $leaf)))
    }
    Check 'WIN-02 sweep keeps another store live temp inside the hour' ([IO.File]::Exists($sweepRecent))
    Check 'WIN-02 sweep keeps a temp newer than the store' ([IO.File]::Exists($sweepLive))
    Check 'WIN-02 sweep leaves the store readable' ((@([IO.File]::ReadAllLines($sweepPath, $StrictUtf8))).Count -ge 1)

    # A NUL byte inside a record must be skipped, not abort the render and not
    # rewrite history. The reader accepts only tab, dot and digits per record.
    $nulRoot = Join-Path $stateRoot 'nulrow'
    $nulConfig = New-StateConfig 'win02-nulrow' $nulRoot 'burn' $false
    $nulPath = Join-Path $nulRoot 'burn.tsv'
    $nulText = (($fixedNow - 300L).ToString($Invariant) + "`t010.000`t1015900`n") +
               (($fixedNow - 200L).ToString($Invariant) + "`t01" + ([char]0) + "0.000`t1015900`n") +
               (($fixedNow - 100L).ToString($Invariant) + "`t020.000`t1015900`n")
    Write-Utf8 $nulPath $nulText
    $nulBefore = ([IO.File]::ReadAllBytes($nulPath)).Length
    $nulRun = Invoke-Statusline (Json $statePayload) $nulConfig $stateEnvRead '' 15000
    Check-Run 'WIN-02 NUL row does not abort the render' $nulRun
    Check 'WIN-02 NUL row leaves the read-only TSV byte exact' ((([IO.File]::ReadAllBytes($nulPath)).Length) -eq $nulBefore)

    # A single record longer than the reader's per-record ceiling is rejected
    # without consuming the rest of the file.
    $longRoot = Join-Path $stateRoot 'longrecord'
    $longConfig = New-StateConfig 'win02-longrecord' $longRoot 'burn' $false
    $longPath = Join-Path $longRoot 'burn.tsv'
    $longText = (('9' * 5000) + "`t010.000`t1015900`n") +
                (($fixedNow - 100L).ToString($Invariant) + "`t020.000`t1015900`n")
    Write-Utf8 $longPath $longText
    $longBefore = ([IO.File]::ReadAllBytes($longPath)).Length
    $longRun = Invoke-Statusline (Json $statePayload) $longConfig $stateEnvRead '' 15000
    Check-Run 'WIN-02 overlong record does not abort the render' $longRun
    Check 'WIN-02 overlong record leaves the read-only TSV byte exact' ((([IO.File]::ReadAllBytes($longPath)).Length) -eq $longBefore)

    # Beyond the byte ceiling the reader refuses to compact the file, so it is
    # never rewritten or truncated. Sampling still appends, exactly as the Bash
    # runtime does: measured on Windows, three mutable renders grow an oversized
    # TSV by 87 bytes in both runtimes. The guard here is that the existing bytes
    # survive untouched, not that the file stops growing.
    $hugeRoot = Join-Path $stateRoot 'hugetsv'
    $hugeConfig = New-StateConfig 'win02-hugetsv' $hugeRoot 'burn' $false
    $hugePath = Join-Path $hugeRoot 'burn.tsv'
    $hugeRow = (($fixedNow - 100L).ToString($Invariant) + "`t010.000`t1015900`n")
    $hugeBuilder = New-Object Text.StringBuilder
    while ($hugeBuilder.Length -le 1048576) { [void]$hugeBuilder.Append($hugeRow) }
    Write-Utf8 $hugePath $hugeBuilder.ToString()
    $hugeOriginal = [IO.File]::ReadAllBytes($hugePath)
    $hugeRun = Invoke-Statusline (Json $statePayload) $hugeConfig $stateEnvWrite '' 30000
    Check-Run 'WIN-02 oversized TSV does not abort the render' $hugeRun
    $hugeAfter = [IO.File]::ReadAllBytes($hugePath)
    $hugePrefixIntact = $hugeAfter.Length -ge $hugeOriginal.Length
    if ($hugePrefixIntact) {
        for ($i = 0; $i -lt $hugeOriginal.Length; $i++) {
            if ($hugeAfter[$i] -ne $hugeOriginal[$i]) { $hugePrefixIntact = $false; break }
        }
    }
    Check 'WIN-02 oversized TSV is never rewritten or truncated' $hugePrefixIntact
    Check 'WIN-02 oversized TSV still accepts the appended sample' ($hugeAfter.Length -gt $hugeOriginal.Length)

    $overRoot = Join-Path $stateRoot 'overcap'
    $overConfig = New-StateConfig 'win02-overcap' $overRoot 'burn' $false
    $overPath = Join-Path $overRoot 'burn.tsv'
    $overLines = New-Object Text.StringBuilder
    for ($i=0; $i -lt 4097; $i++) { [void]$overLines.Append((($fixedNow - $i - 1L).ToString($Invariant) + "`t010.000`t1015900`n")) }
    Write-Utf8 $overPath $overLines.ToString()
    $overPs = Invoke-Statusline (Json $statePayload) $overConfig $stateEnvWrite '' 30000
    Check-Run 'WIN-02 PowerShell burn cap+1 watchdog' $overPs
    Check 'WIN-02 PowerShell burn cap+1 leaves the oversized TSV untrimmed' (([IO.File]::ReadAllLines($overPath, $StrictUtf8)).Count -eq 4098)
    Check 'WIN-02 PowerShell burn cap+1 creates no ignored marker store' (-not [IO.Directory]::Exists((Join-Path $overRoot 'burn.d')))
    $overLimit = Join-Path $overRoot 'limit5.d'
    if ([IO.Directory]::Exists($overLimit)) { [IO.Directory]::Delete($overLimit, $true) }
    [void][IO.Directory]::CreateDirectory($overLimit)
    for ($i=0; $i -lt 513; $i++) { [void][IO.Directory]::CreateDirectory((Join-Path $overLimit ('x' + $i.ToString('D3')))) }
    $overPs2 = Invoke-Statusline (Json $statePayload) $overConfig $stateEnvWrite '' 20000
    Check-Run 'WIN-02 PowerShell limit cap+1 watchdog' $overPs2
    Check 'WIN-02 PowerShell limit cap+1 frozen' ((Get-ImmediateNames $overLimit).Count -eq 513)

    # TSV trim and complete-read caps are distinct boundaries.
    foreach ($rawCount in @(3967,3968,4096)) {
        $boundaryRoot = Join-Path $stateRoot ("burn-boundary-$rawCount")
        $boundaryConfig = New-StateConfig ("win02-burn-boundary-$rawCount") $boundaryRoot 'burn' $false
        $boundaryStore = Join-Path $boundaryRoot 'burn.tsv'
        $boundaryLines = New-Object Text.StringBuilder
        for ($i=0; $i -lt $rawCount; $i++) { [void]$boundaryLines.Append((($fixedNow - $i - 1L).ToString($Invariant) + "`t010.000`t1015900`n")) }
        Write-Utf8 $boundaryStore $boundaryLines.ToString()
        $boundaryRun = Invoke-Statusline (Json $statePayload) $boundaryConfig $stateEnvWrite '' 30000
        Check-Run "WIN-02 PowerShell burn raw boundary $rawCount" $boundaryRun
        $expectedRows = 1500
        if ($rawCount -eq 4096) { $expectedRows = 4097 }
        Check "WIN-02 burn raw boundary $rawCount" (([IO.File]::ReadAllLines($boundaryStore, $StrictUtf8)).Count -eq $expectedRows)
    }
    foreach ($rawCount in @(383,384,512)) {
        $boundaryRoot = Join-Path $stateRoot ("limit-boundary-$rawCount")
        $boundaryConfig = New-StateConfig ("win02-limit-boundary-$rawCount") $boundaryRoot 'limit5h' $true
        $boundaryStore = Join-Path $boundaryRoot 'limit5.d'
        [void][IO.Directory]::CreateDirectory($boundaryStore)
        for ($i=0; $i -lt $rawCount; $i++) { [void][IO.Directory]::CreateDirectory((Join-Path $boundaryStore ('x' + $i.ToString('D3')))) }
        $boundaryRun = Invoke-Statusline (Json $statePayload) $boundaryConfig $stateEnvWrite '' 30000
        Check-Run "WIN-02 PowerShell limit raw boundary $rawCount" $boundaryRun
        $expectedCount = $rawCount
        if ($rawCount -eq 383) { $expectedCount++ }
        Check "WIN-02 limit raw boundary $rawCount publication" ((Get-ImmediateNames $boundaryStore).Count -eq $expectedCount)
    }

    # The default 1500-entry retained set must remain usable on the prompt path.
    $steadyRoot = Join-Path $stateRoot 'steady-1500'
    $steadyConfig = New-StateConfig 'win02-steady-1500' $steadyRoot 'burn' $false
    $steadyStore = Join-Path $steadyRoot 'burn.tsv'
    $steadyBuilder = New-Object Text.StringBuilder
    for ($i=0; $i -lt 1500; $i++) {
        $sample = $fixedNow - $i - 1L
        [void]$steadyBuilder.Append(($sample.ToString($Invariant) + "`t010.000`t1015900`n"))
    }
    Write-Utf8 $steadyStore $steadyBuilder.ToString()
    $steadyPs = Invoke-Statusline (Json $statePayload) $steadyConfig $stateEnvWrite '' 5000
    Check-Run 'WIN-02 PowerShell 1500-entry steady render' $steadyPs
    Check 'WIN-02 PowerShell 1500-entry steady render under 3s' ($steadyPs.ElapsedMs -lt 3000)
    Check 'WIN-02 PowerShell 1500-entry steady render trims to 1500 rows' (([IO.File]::ReadAllLines($steadyStore, $StrictUtf8)).Count -eq 1500)
    $steadyBash = Invoke-BashStatusline (Json $statePayload) $steadyConfig $stateEnvRead
    Check-Run 'WIN-02 Bash 1500-entry steady render' $steadyBash
    Check 'WIN-02 Bash 1500-entry steady render under 3s' ($steadyBash.ElapsedMs -lt 3000)

    # Fixed-clock limit edges are strict for both stores. Only NOW+1 and NOW+max
    # are plausible and publishable; expired/far-future strict sentinels are
    # preserved read-only, then removed only from a complete mutation snapshot.
    foreach ($limitSpec in @(
        [pscustomobject]@{Name='5h'; Segment='limit5h'; RootName='limit5.d'; Max=21600L; Field='five_hour'},
        [pscustomobject]@{Name='7d'; Segment='limit7d'; RootName='limit7.d'; Max=691200L; Field='seven_day'}
    )) {
        foreach ($offset in @(0L,1L,$limitSpec.Max,($limitSpec.Max + 1L))) {
            $edgeRoot = Join-Path $stateRoot ("edge-$($limitSpec.Name)-$offset")
            $edgeConfig = New-StateConfig ("win02-edge-$($limitSpec.Name)-$offset") $edgeRoot $limitSpec.Segment $true
            $edgePayload = Clone-Object $statePayload
            $edgePayload.rate_limits.five_hour.used_percentage = $null
            $edgePayload.rate_limits.five_hour.resets_at = $null
            $edgePayload.rate_limits.seven_day.used_percentage = $null
            $edgePayload.rate_limits.seven_day.resets_at = $null
            $edgePayload.rate_limits.($limitSpec.Field).used_percentage = '33.333'
            $edgePayload.rate_limits.($limitSpec.Field).resets_at = [string]($fixedNow + $offset)
            $edgeRun = Invoke-Statusline (Json $edgePayload) $edgeConfig $stateEnvWrite '' 10000
            Check-Run ("WIN-02 $($limitSpec.Name) reset edge $offset") $edgeRun
            $validEdge = $offset -eq 1L -or $offset -eq $limitSpec.Max
            $edgeStore = Join-Path $edgeRoot $limitSpec.RootName
            $edgeNames = Get-ImmediateNames $edgeStore
            Check ("WIN-02 $($limitSpec.Name) reset edge $offset publication") (($validEdge -and $edgeNames.Count -eq 1) -or (-not $validEdge -and $edgeNames.Count -eq 0))
        }

        $sentinelRoot = Join-Path $stateRoot ('sentinel-' + $limitSpec.Name)
        $sentinelConfig = New-StateConfig ('win02-sentinel-' + $limitSpec.Name) $sentinelRoot $limitSpec.Segment $true
        $sentinelStore = Join-Path $sentinelRoot $limitSpec.RootName
        [void][IO.Directory]::CreateDirectory($sentinelStore)
        $expiredName = $fixedNow.ToString('D10', $Invariant) + '_099.000'
        $futureName = ($fixedNow + $limitSpec.Max + 1L).ToString('D10', $Invariant) + '_099.000'
        [void][IO.Directory]::CreateDirectory((Join-Path $sentinelStore $expiredName))
        [void][IO.Directory]::CreateDirectory((Join-Path $sentinelStore $futureName))
        $sentinelPayload = Clone-Object $statePayload
        $sentinelPayload.rate_limits.five_hour.used_percentage = $null
        $sentinelPayload.rate_limits.five_hour.resets_at = $null
        $sentinelPayload.rate_limits.seven_day.used_percentage = $null
        $sentinelPayload.rate_limits.seven_day.resets_at = $null
        $sentinelPayload.rate_limits.($limitSpec.Field).used_percentage = '20'
        $sentinelPayload.rate_limits.($limitSpec.Field).resets_at = [string]($fixedNow + 1L)
        $sentinelRead = Invoke-Statusline (Json $sentinelPayload) $sentinelConfig $stateEnvRead '' 10000
        Check-Run ("WIN-02 $($limitSpec.Name) sentinel no-sample") $sentinelRead
        Check ("WIN-02 $($limitSpec.Name) no-sample preserves reset sentinels") ((Get-ImmediateNames $sentinelStore).Count -eq 2)
        $sentinelWrite = Invoke-Statusline (Json $sentinelPayload) $sentinelConfig $stateEnvWrite '' 10000
        Check-Run ("WIN-02 $($limitSpec.Name) sentinel mutation") $sentinelWrite
        $sentinelNames = Get-ImmediateNames $sentinelStore
        $expectedName = ($fixedNow + 1L).ToString('D10', $Invariant) + '_020.000'
        Check ("WIN-02 $($limitSpec.Name) complete GC removes only sentinels") ($sentinelNames.Count -eq 1 -and $sentinelNames[0] -ceq $expectedName)
    }

    # Limit high-water is reset-first, then pct within that reset. A rollover to a
    # greater reset cannot be shadowed by an older 90% value, and a lower current
    # payload cannot regress a stored 20% high-water.
    foreach ($limitSpec in @(
        [pscustomobject]@{Name='5h'; Segment='limit5h'; RootName='limit5.d'; Field='five_hour'},
        [pscustomobject]@{Name='7d'; Segment='limit7d'; RootName='limit7.d'; Field='seven_day'}
    )) {
        $highRoot = Join-Path $stateRoot ('highwater-' + $limitSpec.Name)
        $highConfig = New-StateConfig ('win02-highwater-' + $limitSpec.Name) $highRoot $limitSpec.Segment $true
        $highStore = Join-Path $highRoot $limitSpec.RootName
        [void][IO.Directory]::CreateDirectory($highStore)
        foreach ($name in @(
            (($fixedNow + 100L).ToString('D10', $Invariant) + '_090.000'),
            (($fixedNow + 200L).ToString('D10', $Invariant) + '_010.000'),
            (($fixedNow + 200L).ToString('D10', $Invariant) + '_020.000')
        )) { [void][IO.Directory]::CreateDirectory((Join-Path $highStore $name)) }
        $highPayload = Clone-Object $statePayload
        $highPayload.rate_limits.five_hour.used_percentage = $null
        $highPayload.rate_limits.five_hour.resets_at = $null
        $highPayload.rate_limits.seven_day.used_percentage = $null
        $highPayload.rate_limits.seven_day.resets_at = $null
        $highPayload.rate_limits.($limitSpec.Field).used_percentage = '15'
        $highPayload.rate_limits.($limitSpec.Field).resets_at = [string]($fixedNow + 200L)
        $psDump = Join-Path $highRoot 'ps.json'
        $bashDump = Join-Path $highRoot 'bash.txt'
        $psEnv = @{ CORALLINE_NO_SAMPLE='1'; CORALLINE_TEST_NOW=[string]$fixedNow; CORALLINE_TEST_STATE_DUMP=$psDump }
        $bashEnv = @{ CORALLINE_NO_SAMPLE='1'; CORALLINE_TEST_NOW=[string]$fixedNow; CORALLINE_TEST_STATE_DUMP=(Forward-Path $bashDump) }
        $psRun = Invoke-Statusline (Json $highPayload) $highConfig $psEnv '' 10000
        $bashRun = Invoke-BashStatusline (Json $highPayload) $highConfig $bashEnv
        Check-Run ('WIN-02 PowerShell high-water ' + $limitSpec.Name) $psRun
        Check-Run ('WIN-02 Bash high-water ' + $limitSpec.Name) $bashRun
        Check-Exact ('WIN-02 high-water differential ' + $limitSpec.Name) $psRun $bashRun
        $psState = [IO.File]::ReadAllText($psDump, $StrictUtf8) | ConvertFrom-Json
        $bashState = [IO.File]::ReadAllText($bashDump, $StrictUtf8).Trim()
        $prefix = 'Limit5'
        if ($limitSpec.Name -eq '7d') { $prefix = 'Limit7' }
        $psPct = $psState.($prefix + 'Pct')
        $psReset = $psState.($prefix + 'Reset')
        # The store still ranks reset first and pct second, but a session's own
        # reading wins its own window, so the stored 20.000 no longer displaces the
        # payload's 15 the way a pure high-water would.
        Check ('WIN-02 own reading wins its own window ' + $limitSpec.Name) ([string]$psPct -eq '15000' -and [string]$psReset -eq [string]($fixedNow + 200L) -and $bashState.Contains($prefix + 'Pct=15000'))

        # Without a reading of its own the session falls back to the store, which is
        # the only source that knows the account's open window. An entry is admitted
        # only while its reset is still ahead, so the borrowed value cannot be a
        # fossil. Selection is asserted through the state dump and again on the bar.
        $blindPayload = Clone-Object $highPayload
        $blindPayload.rate_limits.($limitSpec.Field).used_percentage = $null
        $blindPayload.rate_limits.($limitSpec.Field).resets_at = $null
        $blindDump = Join-Path $highRoot 'ps-blind.json'
        $blindBashDump = Join-Path $highRoot 'bash-blind.txt'
        $blindPsEnv = @{ CORALLINE_NO_SAMPLE='1'; CORALLINE_TEST_NOW=[string]$fixedNow; CORALLINE_TEST_STATE_DUMP=$blindDump }
        $blindBashEnv = @{ CORALLINE_NO_SAMPLE='1'; CORALLINE_TEST_NOW=[string]$fixedNow; CORALLINE_TEST_STATE_DUMP=(Forward-Path $blindBashDump) }
        $psBlind = Invoke-Statusline (Json $blindPayload) $highConfig $blindPsEnv '' 10000
        $bashBlind = Invoke-BashStatusline (Json $blindPayload) $highConfig $blindBashEnv
        Check-Run ('WIN-02 PowerShell store-only ' + $limitSpec.Name) $psBlind
        Check-Run ('WIN-02 Bash store-only ' + $limitSpec.Name) $bashBlind
        Check-Exact ('WIN-02 store-only differential ' + $limitSpec.Name) $psBlind $bashBlind
        $blindState = [IO.File]::ReadAllText($blindDump, $StrictUtf8) | ConvertFrom-Json
        $blindBash = [IO.File]::ReadAllText($blindBashDump, $StrictUtf8).Trim()
        Check ('WIN-02 store still selects the canonical winner ' + $limitSpec.Name) ([string]$blindState.($prefix + 'Pct') -eq '20000' -and $blindBash.Contains($prefix + 'Pct=20000'))
        Check ('WIN-02 a blind session shows the stored window ' + $limitSpec.Name) ($psBlind.Stdout.Contains($limitSpec.Name + ' ') -and $psBlind.Stdout.Contains('20%'))

        $highPayload.rate_limits.($limitSpec.Field).used_percentage = '25'
        $writeRun = Invoke-Statusline (Json $highPayload) $highConfig $stateEnvWrite '' 10000
        Check-Run ('WIN-02 PowerShell high-water advance ' + $limitSpec.Name) $writeRun
        $highNames = Get-ImmediateNames $highStore
        $expectedHigh = ($fixedNow + 200L).ToString('D10', $Invariant) + '_025.000'
        Check ('WIN-02 high-water advances without regression ' + $limitSpec.Name) ($highNames -contains $expectedHigh)
        $maintenanceRun = Invoke-Statusline (Json $highPayload) $highConfig $stateEnvWrite '' 10000
        Check-Run ('WIN-02 PowerShell high-water maintenance ' + $limitSpec.Name) $maintenanceRun
        $highNames = Get-ImmediateNames $highStore
        Check ('WIN-02 high-water maintenance converges ' + $limitSpec.Name) ($highNames.Count -eq 1 -and $highNames[0] -ceq $expectedHigh)
    }

    # An elapsed window keeps its last canonical reading on the bar. Both runtimes
    # stop treating the payload snapshot and every store entry as valid the moment
    # resets_at passes, and Claude Code re-renders an idle session from its
    # last-seen snapshot, so gating the segment on validity blanked it for the
    # whole idle stretch. Read-only mode leaves the payload as the only source.
    $elapsedRoot = Join-Path $stateRoot 'elapsed'
    $elapsedConfig = New-StateConfig 'win02-elapsed' $elapsedRoot 'limit5h limit7d' $true
    $elapsedEnv = @{ CORALLINE_NO_SAMPLE='1'; CORALLINE_TEST_NOW=[string]$fixedNow }
    $elapsedPayload = Clone-Object $statePayload
    $elapsedPayload.rate_limits.five_hour.used_percentage = '41.2'
    $elapsedPayload.rate_limits.five_hour.resets_at = [string]($fixedNow - 60L)
    $elapsedPayload.rate_limits.seven_day.used_percentage = '30'
    $elapsedPayload.rate_limits.seven_day.resets_at = [string]($fixedNow + 345600L)
    $psElapsed = Invoke-Statusline (Json $elapsedPayload) $elapsedConfig $elapsedEnv '' 10000
    $bashElapsed = Invoke-BashStatusline (Json $elapsedPayload) $elapsedConfig $elapsedEnv
    Check-Run 'WIN-02 PowerShell elapsed 5h window' $psElapsed
    Check-Run 'WIN-02 Bash elapsed 5h window' $bashElapsed
    Check 'WIN-02 elapsed 5h window still renders its last reading' ($psElapsed.Stdout.Contains('5h ') -and $psElapsed.Stdout.Contains('41%'))
    Check-Exact 'WIN-02 elapsed 5h window differential' $psElapsed $bashElapsed

    # A malformed pct leaves no canonical reading at all, so the fallback must
    # draw nothing rather than push an unvalidated payload word through the bar.
    $malformedPayload = Clone-Object $elapsedPayload
    $malformedPayload.rate_limits.five_hour.used_percentage = '1e2'
    $psMalformed = Invoke-Statusline (Json $malformedPayload) $elapsedConfig $elapsedEnv '' 10000
    $bashMalformed = Invoke-BashStatusline (Json $malformedPayload) $elapsedConfig $elapsedEnv
    Check-Run 'WIN-02 PowerShell elapsed malformed pct' $psMalformed
    Check-Run 'WIN-02 Bash elapsed malformed pct' $bashMalformed
    Check 'WIN-02 unvalidated pct draws no 5h segment' (-not $psMalformed.Stdout.Contains('5h '))
    Check-Exact 'WIN-02 elapsed malformed pct differential' $psMalformed $bashMalformed

    # A canonical pct is not on its own evidence of an elapsed window. An
    # unparsable reset and a sentinel reset beyond the window ceiling both leave
    # no observed window, so neither runtime may invent a countdown for one.
    # The elapsed fallback is for a window that JUST closed. Claude Code replays the
    # last snapshot an idle session received indefinitely, so once the reading is
    # older than the window ceiling it stops standing in for the current window.
    # Both runtimes take the bound from the same constant, hence the shared vector.
    foreach ($resetSpec in @(
        [pscustomobject]@{ Name='unparsed reset'; Value='not-an-epoch' },
        [pscustomobject]@{ Name='sentinel reset'; Value=[string]($fixedNow + 999999L) },
        [pscustomobject]@{ Name='stale elapsed reset'; Value=[string]($fixedNow - 21601L) }
    )) {
        $resetPayload = Clone-Object $elapsedPayload
        $resetPayload.rate_limits.five_hour.resets_at = $resetSpec.Value
        $psReset = Invoke-Statusline (Json $resetPayload) $elapsedConfig $elapsedEnv '' 10000
        $bashReset = Invoke-BashStatusline (Json $resetPayload) $elapsedConfig $elapsedEnv
        Check-Run ('WIN-02 PowerShell ' + $resetSpec.Name) $psReset
        Check-Run ('WIN-02 Bash ' + $resetSpec.Name) $bashReset
        Check ('WIN-02 ' + $resetSpec.Name + ' draws no 5h segment') (-not $psReset.Stdout.Contains('5h '))
        Check-Exact ('WIN-02 ' + $resetSpec.Name + ' differential') $psReset $bashReset
    }

    # Mutable burn state is a single TSV. Existing marker trees remain ignored
    # during append, trim, and healing.
    $coexistRoot = Join-Path $stateRoot 'coexist'
    $coexistConfig = New-StateConfig 'win02-coexist' $coexistRoot 'burn' $false
    $coexistMarker = Join-Path $coexistRoot 'burn.d'
    [void][IO.Directory]::CreateDirectory($coexistMarker)
    $coexistSentinel = Join-Path $coexistMarker 'legacy-marker'
    Write-Utf8 $coexistSentinel 'keep'
    $coexistBefore = Snapshot-StateTree $coexistMarker
    Write-Utf8 (Join-Path $coexistRoot 'burn.tsv') "999900`t010.000`t1015900`n"
    $coexistPayload = Clone-Object $statePayload
    $coexistPayload.rate_limits.five_hour.used_percentage = '1.2355'
    $coexistRun = Invoke-Statusline (Json $coexistPayload) $coexistConfig $stateEnvWrite '' 10000
    Check-Run 'WIN-02 mutable TSV coexistence' $coexistRun
    $coexistRows = [IO.File]::ReadAllLines((Join-Path $coexistRoot 'burn.tsv'), $StrictUtf8)
    Check 'WIN-02 mutable TSV canonical culture row' ($coexistRows -contains "1000000`t1.236`t1015900")
    Check 'WIN-02 mutable TSV leaves marker tree byte exact' ((Snapshot-StateTree $coexistMarker) -ceq $coexistBefore)

    # State path positive controls plus ADS, junction, symlink, UNC, and device
    # negatives. Required NTFS capabilities are failures, never BLOCKED.
    $pathRoot = Join-Path $stateRoot 'paths'
    $pathPositive = New-StateConfig 'win02-path-positive' (Join-Path $pathRoot 'positive') 'burn' $false
    $pathPositiveRun = Invoke-Statusline (Json $statePayload) $pathPositive $stateEnvWrite '' 10000
    Check-Run 'WIN-02 state path positive control' $pathPositiveRun
    $positivePath = Join-Path $pathRoot 'positive\burn.tsv'
    Check 'WIN-02 state path positive control reaches write' ([IO.File]::Exists($positivePath))
    $positiveStore = Join-Path $pathRoot 'positive\burn.d'
    [void][IO.Directory]::CreateDirectory($positiveStore)
    $positiveSentinel = Join-Path $positiveStore 'legacy-marker'
    Write-Utf8 $positiveSentinel 'keep'
    $positiveBefore = Snapshot-StateTree $positiveStore
    $pathPositiveGc = Invoke-Statusline (Json $statePayload) $pathPositive $stateEnvWrite '' 10000
    Check-Run 'WIN-02 state path positive GC control' $pathPositiveGc
    Check 'WIN-02 state path positive marker tree remains untouched' ((Snapshot-StateTree $positiveStore) -ceq $positiveBefore)

    $adsCarrier = Join-Path $pathRoot 'ads-carrier'
    [void][IO.Directory]::CreateDirectory($pathRoot)
    [IO.File]::WriteAllText($adsCarrier, 'primary', $Utf8NoBom)
    $adsReady = $true
    try { Set-Content -LiteralPath $adsCarrier -Stream canary -Value 'stream' -NoNewline -ErrorAction Stop } catch { $adsReady=$false }
    Check 'WIN-02 NTFS ADS capability available' $adsReady
    if ($adsReady) {
        $adsBefore = Snapshot-Ads $adsCarrier canary
        $adsConfig = New-Config 'win02-path-ads' @('VL_SEGMENTS=burn','VL_CLOCK=off',("BURN_FILE='" + (Forward-Path $adsCarrier) + ":burn.tsv'"))
        $adsRun = Invoke-Statusline (Json $statePayload) $adsConfig $stateEnvWrite '' 10000
        Check-Run 'WIN-02 ADS state rejection' $adsRun
        Check 'WIN-02 ADS state canary unchanged' ((Snapshot-Ads $adsCarrier canary) -eq $adsBefore)
    }

    $junctionTarget = Join-Path $pathRoot 'junction-target'
    $junctionLink = Join-Path $pathRoot 'junction-link'
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    $mkJunction = Invoke-CapturedProcess $env:ComSpec ('/d /s /c "mklink /J ""' + $junctionLink + '"" ""' + $junctionTarget + '"""') '' @{} $Repo 5000
    $junctionReady = $mkJunction.ExitCode -eq 0 -and [IO.Directory]::Exists($junctionLink)
    Check 'WIN-02 NTFS junction capability available' $junctionReady
    if ($junctionReady) {
        $junctionTargetPath = Join-Path $junctionTarget 'burn.tsv'
        Write-Utf8 $junctionTargetPath "1000000`t010.000`t1015900`n"
        $junctionBefore = Snapshot-File $junctionTargetPath
        $junctionConfig = New-Config 'win02-path-junction' @('VL_SEGMENTS=burn','VL_CLOCK=off',("BURN_FILE='" + (Forward-Path (Join-Path $junctionLink 'burn.tsv')) + "'"))
        $junctionRun = Invoke-Statusline (Json $statePayload) $junctionConfig $stateEnvWrite '' 10000
        Check-Run 'WIN-02 junction state rejection' $junctionRun
        Check 'WIN-02 junction target receives no append or trim' ((Snapshot-File $junctionTargetPath) -ceq $junctionBefore)
    }

    $symlinkTarget = Join-Path $pathRoot 'symlink-target'
    $symlinkLink = Join-Path $pathRoot 'symlink-link'
    [void][IO.Directory]::CreateDirectory($symlinkTarget)
    $mkSymlink = Invoke-CapturedProcess $env:ComSpec ('/d /s /c "mklink /D ""' + $symlinkLink + '"" ""' + $symlinkTarget + '"""') '' @{} $Repo 5000
    $symlinkReady = $mkSymlink.ExitCode -eq 0 -and [IO.Directory]::Exists($symlinkLink)
    Check 'WIN-02 NTFS directory symlink capability available' $symlinkReady
    if ($symlinkReady) {
        $symlinkTargetPath = Join-Path $symlinkTarget 'burn.tsv'
        Write-Utf8 $symlinkTargetPath "1000000`t010.000`t1015900`n"
        $symlinkBefore = Snapshot-File $symlinkTargetPath
        $symlinkConfig = New-Config 'win02-path-symlink' @('VL_SEGMENTS=burn','VL_CLOCK=off',("BURN_FILE='" + (Forward-Path (Join-Path $symlinkLink 'burn.tsv')) + "'"))
        $symlinkRun = Invoke-Statusline (Json $statePayload) $symlinkConfig $stateEnvWrite '' 10000
        Check-Run 'WIN-02 directory symlink state rejection' $symlinkRun
        Check 'WIN-02 directory symlink target receives no append or trim' ((Snapshot-File $symlinkTargetPath) -ceq $symlinkBefore)
    }

    $fileTarget = Join-Path $pathRoot 'state-target.tsv'
    $fileLink = Join-Path $pathRoot 'state-link.tsv'
    Write-Utf8 $fileTarget "1000000`t1`t1015900`n"
    $mkFileLink = Invoke-CapturedProcess $env:ComSpec ('/d /s /c "mklink ""' + $fileLink + '"" ""' + $fileTarget + '"""') '' @{} $Repo 5000
    $fileLinkReady = $mkFileLink.ExitCode -eq 0 -and [IO.File]::Exists($fileLink)
    Check 'WIN-02 NTFS file symlink capability available' $fileLinkReady
    if ($fileLinkReady) {
        $fileBefore = Snapshot-File $fileTarget
        $fileLinkConfig = New-Config 'win02-path-file-link' @('VL_SEGMENTS=burn','VL_CLOCK=off',("BURN_FILE='" + (Forward-Path $fileLink) + "'"))
        $fileLinkRun = Invoke-Statusline (Json $statePayload) $fileLinkConfig $stateEnvWrite '' 10000
        Check-Run 'WIN-02 file symlink state rejection' $fileLinkRun
        Check 'WIN-02 file symlink target unchanged' ((Snapshot-File $fileTarget) -eq $fileBefore)
    }

    $localStateBase = Join-Path $pathRoot 'unc-local\burn.tsv'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($localStateBase))
    $driveRoot = [IO.Path]::GetPathRoot($localStateBase)
    $uncStateBase = '\\localhost\' + $driveRoot.Substring(0,1) + '$\' + $localStateBase.Substring($driveRoot.Length)
    $uncProbe = Invoke-CapturedProcess $PowerShellExe ('-NoProfile -Command "[IO.File]::WriteAllText(''' + $uncStateBase + ''',''probe''); [IO.File]::Delete(''' + $uncStateBase + ''')"') '' @{} $Repo 5000
    $uncReady = $uncProbe.ExitCode -eq 0 -and -not $uncProbe.TimedOut
    Check 'WIN-02 loopback UNC capability available' $uncReady
    if ($uncReady) {
        $uncConfig = New-Config 'win02-path-unc' @('VL_SEGMENTS=burn','VL_CLOCK=off',("BURN_FILE='" + $uncStateBase + "'"))
        $uncRun = Invoke-Statusline (Json $statePayload) $uncConfig $stateEnvWrite '' 5000
        Check-Run 'WIN-02 UNC state rejection' $uncRun
        Check 'WIN-02 UNC state rejection is pre-I/O' (-not [IO.File]::Exists($localStateBase))

        $uncGitRoot = '\\localhost\' + $driveRoot.Substring(0,1) + '$\' + $gitRoot.Substring($driveRoot.Length)
        $uncPayload = New-Payload $uncGitRoot
        $uncProbeConfig = New-Config 'win03-unc-read-probes' @('VL_SEGMENTS=git\ stash\ project\ node\ python','VL_CLOCK=off')
        $uncProbeRun = Invoke-Statusline (Json $uncPayload) $uncProbeConfig @{} '' 10000
        $uncProbePlain = Plain $uncProbeRun.Stdout
        Check-Run 'WIN-03 UNC read-only workspace probes' $uncProbeRun
        Check 'WIN-03 UNC git and project probes render' ($uncProbePlain.Contains('main') -and $uncProbePlain.Contains($repoLeaf))
        Check 'WIN-03 UNC stash probe renders' ($uncProbePlain.Contains((Glyph 0x2691) + ' 1 '))
        Check 'WIN-03 UNC runtime pin probes render' ($uncProbePlain.Contains('20.11.1') -and $uncProbePlain.Contains('3.12.2'))
    }

    foreach ($deviceBase in @('\\?\' + $localStateBase, '\\.\' + $localStateBase)) {
        $deviceConfig = New-Config ('win02-path-device-' + [Math]::Abs($deviceBase.GetHashCode())) @('VL_SEGMENTS=burn','VL_CLOCK=off',("BURN_FILE='" + $deviceBase + "'"))
        $deviceRun = Invoke-Statusline (Json $statePayload) $deviceConfig $stateEnvWrite '' 5000
        Check-Run 'WIN-02 device namespace state rejection' $deviceRun
        Check 'WIN-02 device namespace creates no store' (-not [IO.File]::Exists($localStateBase))
    }

    $subagentRun = Invoke-Statusline '' '\\localhost\never\touch.conf' @{} '--subagent' 5000
    Check-Run 'literal subagent early route' $subagentRun
    Check 'literal subagent route emits no main output' ($subagentRun.StdoutBytes.Length -eq 0)

    $secRoot = Join-Path $TempRoot 'security'
    $secConfigRoot = Join-Path $secRoot 'config'
    $secOutside = Join-Path $secRoot 'outside'
    [void][System.IO.Directory]::CreateDirectory($secConfigRoot)
    [void][System.IO.Directory]::CreateDirectory($secOutside)
    $evil = Join-Path $secOutside 'evil.conf'
    Write-Utf8 $evil "VL_BG_MODEL=99`n"
    $evilBefore = Snapshot-File $evil

    $sec01 = Join-Path $secConfigRoot 'sec-inc-01.conf'
    Write-Utf8 $sec01 "VL_SEGMENTS=model`nVL_CLOCK=off`n. ../outside/evil.conf`n"
    $run01 = Run-ModelColor 'SEC-INC-01 traversal rejection' $sec01 '173' @{}
    Check 'SEC-INC-01 outside canary unchanged' ((Snapshot-File $evil) -eq $evilBefore)
    Check 'SEC-INC-01 completes within five seconds' ($run01.ElapsedMs -lt 5000)
    Assert-NoUnexpectedResidue $secRoot 'SEC-INC-01'

    $uncCanaryRoot = [IO.Path]::GetPathRoot($evil)
    $uncCanary = '\\localhost\' + $uncCanaryRoot.Substring(0,1) + '$\' + $evil.Substring($uncCanaryRoot.Length)
    $probeCommand = "try { [IO.File]::ReadAllText('$uncCanary') | Out-Null; exit 0 } catch { exit 2 }"
    $uncProbe = Invoke-CapturedProcess $PowerShellExe ('-NoLogo -NoProfile -NonInteractive -Command "' + $probeCommand + '"') '' @{} $Repo 3000
    $staticUnc = $source.IndexOf("StartsWith('\\'") -ge 0 -and $source.IndexOf("StartsWith('\\'") -lt $source.IndexOf('GetFullPath($p)')
    if ($uncProbe.ExitCode -eq 0 -and -not $uncProbe.TimedOut) {
        $sec02 = Join-Path $secConfigRoot 'sec-inc-02.conf'
        Write-Utf8 $sec02 ("VL_SEGMENTS=model`nVL_CLOCK=off`n. '$uncCanary'`n")
        $run02 = Run-ModelColor 'SEC-INC-02 UNC rejection' $sec02 '173' @{}
        Check 'SEC-INC-02 rejects before five-second watchdog' ($run02.ElapsedMs -lt 5000)
        Check 'SEC-INC-02 canary unchanged' ((Snapshot-File $evil) -eq $evilBefore)
        Check 'SEC-INC-02 static pre-I/O ordering evidence' $staticUnc
    } else {
        Check 'SEC-INC-02 static pre-I/O ordering evidence' $staticUnc
        Blocked 'SEC-INC-02' 'readable loopback UNC share unavailable on host'
    }

    foreach ($device in @('\\?\' + $evil, '\\.\' + $evil)) {
        $sec03 = Join-Path $secConfigRoot ('sec-inc-03-' + [Math]::Abs($device.GetHashCode()) + '.conf')
        Write-Utf8 $sec03 ("VL_SEGMENTS=model`nVL_CLOCK=off`n. '$device'`n")
        $run03 = Run-ModelColor 'SEC-INC-03 device namespace rejection' $sec03 '173' @{}
        Check 'SEC-INC-03 canary unchanged' ((Snapshot-File $evil) -eq $evilBefore)
        Check 'SEC-INC-03 completes within five seconds' ($run03.ElapsedMs -lt 5000)
    }

    $carrier = Join-Path $secConfigRoot 'carrier.txt'
    Write-Utf8 $carrier 'PRIMARY'
    $adsAvailable = $true
    try {
        Set-Content -LiteralPath $carrier -Stream 'evil.conf' -Value 'VL_BG_MODEL=99' -Encoding UTF8 -NoNewline -ErrorAction Stop
        $adsBefore = Snapshot-Ads $carrier 'evil.conf'
        if ($null -eq $adsBefore) { $adsAvailable = $false }
    } catch { $adsAvailable = $false }
    if ($adsAvailable) {
        $primaryBefore = Snapshot-File $carrier
        $sec04 = Join-Path $secConfigRoot 'sec-inc-04.conf'
        Write-Utf8 $sec04 "VL_SEGMENTS=model`nVL_CLOCK=off`n. carrier.txt:evil.conf`n"
        [void](Run-ModelColor 'SEC-INC-04 ADS rejection' $sec04 '173' @{})
        Check 'SEC-INC-04 primary stream unchanged' ((Snapshot-File $carrier) -eq $primaryBefore)
        Check 'SEC-INC-04 alternate stream unchanged' ((Snapshot-Ads $carrier 'evil.conf') -eq $adsBefore)
    } else { Blocked 'SEC-INC-04' 'NTFS alternate data streams unavailable' }

    $junction = Join-Path $secConfigRoot 'theme-link'
    $mkArgs = '/d /s /c "mklink /J ""' + $junction + '"" ""' + $secOutside + '"""'
    $mk = Invoke-CapturedProcess $env:ComSpec $mkArgs '' @{} $Repo 5000
    $junctionReady = $mk.ExitCode -eq 0 -and [System.IO.Directory]::Exists($junction)
    $staticReparse = $source.IndexOf('FileAttributes]::ReparsePoint') -ge 0 -and $source.IndexOf('Test-NoReparseComponents $Path') -lt $source.IndexOf('ReadAllBytes($Path)')
    if ($junctionReady) {
        $linkAttrsBefore = [System.IO.File]::GetAttributes($junction)
        $sec05 = Join-Path $secConfigRoot 'sec-inc-05.conf'
        Write-Utf8 $sec05 "VL_SEGMENTS=model`nVL_CLOCK=off`n. theme-link/evil.conf`n"
        [void](Run-ModelColor 'SEC-INC-05 junction rejection' $sec05 '173' @{})
        $linkAttrsAfter = [System.IO.File]::GetAttributes($junction)
        Check 'SEC-INC-05 junction identity remains reparse point' (($linkAttrsBefore -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and ($linkAttrsAfter -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        Check 'SEC-INC-05 outside canary unchanged' ((Snapshot-File $evil) -eq $evilBefore)
        Check 'SEC-INC-05 static no-follow ordering evidence' $staticReparse
    } else {
        Check 'SEC-INC-05 static no-follow ordering evidence' $staticReparse
        Blocked 'SEC-INC-05' 'junction creation capability unavailable'
    }
    Assert-NoUnexpectedResidue $secRoot 'SEC-INC matrix'

    # WIN-03 style/layout/float producer matrix.
    $win03Root = Join-Path $TempRoot 'win03'
    [void][IO.Directory]::CreateDirectory($win03Root)
    $styleCases = @(
        [pscustomobject]@{ Name='pill'; Lines=@('VL_STYLE=pill') },
        [pscustomobject]@{ Name='lean'; Lines=@('VL_STYLE=lean',('VL_LEAN_SEP=' + (Quote-FromConfigure '|'))) },
        [pscustomobject]@{ Name='classic'; Lines=@('VL_STYLE=classic') },
        [pscustomobject]@{ Name='ascii'; Lines=@('VL_ASCII=1') },
        [pscustomobject]@{ Name='classic-ascii'; Lines=@('VL_STYLE=classic','VL_ASCII=1') },
        [pscustomobject]@{ Name='lean-bar'; Lines=@('VL_STYLE=lean','VL_LEAN_BG=238','VL_LEAN_FG=231',('VL_LEAN_CAP_L=' + (Quote-FromConfigure '<')),('VL_LEAN_CAP_R=' + (Quote-FromConfigure '>')),('VL_LEAN_SEP=' + (Quote-FromConfigure '|'))) }
    )
    foreach ($case in $styleCases) {
        $styleConfig = New-Config ('win03-style-' + $case.Name) (@('VL_SEGMENTS=model\ ctx\ cost','VL_CLOCK=off') + $case.Lines)
        $psStyle = Invoke-Statusline (Json $basePayload) $styleConfig @{} '' 10000
        $bashStyle = Invoke-BashStatusline (Json $basePayload) $styleConfig @{}
        Check-Run ('WIN-03 PowerShell style ' + $case.Name) $psStyle
        Check-Run ('WIN-03 Bash style ' + $case.Name) $bashStyle
        Check-Exact ('WIN-03 style differential ' + $case.Name) $psStyle $bashStyle
    }
    $invalidColorConfig = New-Config 'win03-invalid-lean-color' @('VL_SEGMENTS=model','VL_CLOCK=off','VL_STYLE=lean','VL_LEAN_BG=2J','VL_LEAN_FG=999999')
    $invalidColorRun = Invoke-Statusline (Json $basePayload) $invalidColorConfig @{} '' 10000
    Check-Run 'WIN-03 invalid lean color' $invalidColorRun
    Check 'WIN-03 invalid lean color cannot inject CSI' (-not $invalidColorRun.Stdout.Contains(([string][char]27 + '[2J')))

    foreach ($columns in @('1','20','40','32767','0','bad','999999999999')) {
        $autoConfig = New-Config ('win03-auto-' + $columns) @('VL_SEGMENTS=model\ ctx\ cost\ lines','VL_CLOCK=off','VL_LAYOUT=auto','VL_MAX_LINES=3','VL_WRAP_MARGIN=0')
        $env = @{ COLUMNS=$columns }
        $psAuto = Invoke-Statusline (Json $basePayload) $autoConfig $env '' 10000
        $bashAuto = Invoke-BashStatusline (Json $basePayload) $autoConfig $env
        Check-Run ('WIN-03 PowerShell auto width ' + $columns) $psAuto
        Check-Run ('WIN-03 Bash auto width ' + $columns) $bashAuto
        Check-Exact ('WIN-03 auto width differential ' + $columns) $psAuto $bashAuto
    }
    $unicodePayload = Clone-Object $basePayload
    $unicodePayload.model.display_name = 'Claude ' + (Glyph 0x1F600) + (Glyph 0x0301) + (Glyph 0xFF21)
    $unicodeConfig = New-Config 'win03-auto-unicode' @('VL_SEGMENTS=model\ ctx\ cost','VL_CLOCK=off','VL_LAYOUT=auto','VL_MAX_LINES=2','VL_WRAP_MARGIN=0')
    $unicodePs = Invoke-Statusline (Json $unicodePayload) $unicodeConfig @{ COLUMNS='24' } '' 10000
    $unicodeBash = Invoke-BashStatusline (Json $unicodePayload) $unicodeConfig @{ COLUMNS='24' }
    Check-Run 'WIN-03 Unicode width PowerShell' $unicodePs
    Check-Run 'WIN-03 Unicode width Bash' $unicodeBash
    Check-Exact 'WIN-03 Unicode width differential' $unicodePs $unicodeBash

    $fixedWidthSource = $source.Replace('function Get-DisplayWidth([string]$Value) {', 'function Get-DisplayWidth([string]$Value) { throw ''fixed layout entered width helper''')
    $script:WidthScript = Join-Path $TempRoot 'statusline-width-test.ps1'
    Write-Utf8 $script:WidthScript $fixedWidthSource
    $fixedWidthConfig = New-Config 'win03-fixed-no-width-scan' @('VL_SEGMENTS=model','VL_CLOCK=off','VL_LAYOUT=fixed')
    $fixedWidthRun = Invoke-Statusline (Json $basePayload) $fixedWidthConfig @{ CORALLINE_TEST_WIDTH_SCRIPT='1'; COLUMNS='1' } '' 10000
    Check-Run 'WIN-03 fixed layout skips width helper' $fixedWidthRun
    Check 'WIN-03 fixed layout source has no width test hook' (-not $source.Contains('CORALLINE_TEST_WIDTH_SCRIPT'))
    Check 'WIN-03 RawUI width is ConsoleHost-only' $source.Contains("if (`$Host.Name -ne 'ConsoleHost') { return 0 }")

    $floatTarget = Join-Path $win03Root 'float output\float.txt'
    $floatConfig = New-FloatConfig 'win03-float-standard' $floatTarget 'model ctx cost' '  |  ' @()
    $floatPs = Invoke-Float (Json $basePayload) $floatConfig @{}
    Check-Run 'WIN-03 standard float PowerShell' $floatPs
    $floatPsBytes = Float-Bytes $floatTarget
    Check 'WIN-03 float creates UTF-8 no-BOM LF file' ($null -ne $floatPsBytes -and $floatPsBytes.Length -gt 0 -and $floatPsBytes[0] -ne 0xEF -and $floatPsBytes[$floatPsBytes.Length - 1] -eq 10 -and -not ($floatPsBytes -contains [byte]13))
    Check 'WIN-03 float has one trailing LF and no ESC' ($floatPsBytes.Length -eq 0 -or ($floatPsBytes[$floatPsBytes.Length - 1] -eq 10 -and -not ($floatPsBytes[0..($floatPsBytes.Length - 1)] -contains [byte]27)))
    $floatOld = [byte[]]@(0x6f,0x6c,0x64,0x0a)
    [IO.File]::WriteAllBytes($floatTarget, $floatOld)
    $floatReplace = Invoke-Float (Json $basePayload) $floatConfig @{}
    Check-Run 'WIN-03 existing float replacement' $floatReplace
    $replacedBytes = Float-Bytes $floatTarget
    Check 'WIN-03 local File.Replace changes complete destination' ((-not (Bytes-Same $replacedBytes $floatOld)) -and $replacedBytes.Length -gt 1 -and $replacedBytes[$replacedBytes.Length - 1] -eq 10)
    Check 'WIN-03 float leaves no temp artifact' (@(Get-ChildItem -LiteralPath (Split-Path $floatTarget -Parent) -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.float.tmp.*' }).Count -eq 0)

    $readonlyTarget = Join-Path $win03Root 'readonly.txt'
    [IO.File]::WriteAllBytes($readonlyTarget, $floatOld)
    $readonlyInfo = Get-Item -LiteralPath $readonlyTarget -Force
    $readonlyInfo.Attributes = $readonlyInfo.Attributes -bor [IO.FileAttributes]::ReadOnly
    $readonlyBefore = Snapshot-File $readonlyTarget
    $readonlyAttrBefore = (Get-Item -LiteralPath $readonlyTarget -Force).Attributes
    $readonlyRun = Invoke-Float (Json $basePayload) (New-FloatConfig 'win03-float-readonly' $readonlyTarget 'model' '|' @()) @{}
    Check-Run 'WIN-03 read-only float target' $readonlyRun
    Check 'WIN-03 read-only target remains unchanged' ((Snapshot-File $readonlyTarget) -eq $readonlyBefore -and (Get-Item -LiteralPath $readonlyTarget -Force).Attributes -eq $readonlyAttrBefore)
    $readonlyInfo.Attributes = $readonlyInfo.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)

    $observerTarget = Join-Path $win03Root 'observer.txt'
    [IO.File]::WriteAllBytes($observerTarget, $floatOld)
    $observerBarrier = Join-Path $win03Root 'observer-release'
    $observerConfig = New-FloatConfig 'win03-float-observer' $observerTarget 'model ctx' '|' @()
    $observerHandle = Start-FloatAsync (Json $basePayload) $observerConfig @{ CORALLINE_TEST_FLOAT_SCRIPT='1'; CORALLINE_TEST_FLOAT_AFTER_TEMP=$observerBarrier }
    $observerReady = Wait-Ready $observerBarrier 5000
    Check 'WIN-03 atomic observer reaches post-close barrier' $observerReady
    $observerOnlyOld = $true
    if ($observerReady) {
        for ($i=0; $i -lt 20; $i++) { if (-not (Bytes-Same (Float-Bytes $observerTarget) $floatOld)) { $observerOnlyOld=$false; break }; Start-Sleep -Milliseconds 5 }
    }
    [IO.File]::WriteAllBytes($observerBarrier, [byte[]]@())
    $observerResult = Wait-CapturedProcessAsync $observerHandle 15000
    Check-Run 'WIN-03 atomic observer writer' $observerResult
    Check 'WIN-03 atomic observer sees old then complete new' ($observerOnlyOld -and -not (Bytes-Same (Float-Bytes $observerTarget) $floatOld) -and (Float-Bytes $observerTarget)[(Float-Bytes $observerTarget).Length - 1] -eq 10)
    Remove-Item -LiteralPath $observerBarrier -Force -ErrorAction SilentlyContinue

    $junctionProbeRoot = Join-Path $win03Root 'junction-capability'
    [void][IO.Directory]::CreateDirectory($junctionProbeRoot)
    $junctionProbeTarget = Join-Path $junctionProbeRoot 'outside'
    [void][IO.Directory]::CreateDirectory($junctionProbeTarget)
    $junctionProbeLink = Join-Path $junctionProbeRoot 'link'
    $junctionProbe = Invoke-CapturedProcess $env:ComSpec ('/d /s /c "mklink /J ""' + $junctionProbeLink + '"" ""' + $junctionProbeTarget + '"""') '' @{} $Repo 5000
    $win03JunctionReady = $junctionProbe.ExitCode -eq 0 -and [IO.Directory]::Exists($junctionProbeLink)
    Check 'WIN-03 required local junction capability' $win03JunctionReady
    if ($win03JunctionReady) {
        Remove-Item -LiteralPath $junctionProbeLink -Force -ErrorAction SilentlyContinue
        foreach ($barrierCase in @('before-parent','after-parent','after-temp')) {
            $caseRoot = Join-Path $win03Root ('reparse-' + $barrierCase)
            $outside = Join-Path $caseRoot 'outside'
            $parent = Join-Path $caseRoot 'parent'
            $target = Join-Path $parent 'float.txt'
            $link = Join-Path $caseRoot 'link-target'
            $barrier = Join-Path $caseRoot 'release'
            [void][IO.Directory]::CreateDirectory($outside)
            $barrierExtra = @{ CORALLINE_TEST_FLOAT_SCRIPT='1' }
            if ($barrierCase -eq 'before-parent') { $barrierExtra.CORALLINE_TEST_FLOAT_BEFORE_PARENT=$barrier }
            elseif ($barrierCase -eq 'after-parent') { [void][IO.Directory]::CreateDirectory($parent); $barrierExtra.CORALLINE_TEST_FLOAT_AFTER_PARENT=$barrier }
            else { [void][IO.Directory]::CreateDirectory($parent); $barrierExtra.CORALLINE_TEST_FLOAT_AFTER_TEMP=$barrier }
            $caseConfig = New-FloatConfig ('win03-reparse-' + $barrierCase) $target 'model' '|' @()
            $handle = $null
            try {
                $handle = Start-FloatAsync (Json $basePayload) $caseConfig $barrierExtra
                $ready = Wait-Ready $barrier 5000
                Check ('WIN-03 ' + $barrierCase + ' barrier reaches hook') $ready
                if ($ready) {
                    if ($barrierCase -eq 'before-parent') {
                        $mk = Invoke-CapturedProcess $env:ComSpec ('/d /s /c "mklink /J ""' + $parent + '"" ""' + $outside + '"""') '' @{} $Repo 5000
                    } elseif ($barrierCase -eq 'after-parent') {
                        Remove-Item -LiteralPath $parent -Force -Recurse
                        $mk = Invoke-CapturedProcess $env:ComSpec ('/d /s /c "mklink /J ""' + $parent + '"" ""' + $outside + '"""') '' @{} $Repo 5000
                    } else {
                        $backup = Join-Path $caseRoot 'parent-backup'
                        [IO.Directory]::Move($parent, $backup)
                        $mk = Invoke-CapturedProcess $env:ComSpec ('/d /s /c "mklink /J ""' + $parent + '"" ""' + $outside + '"""') '' @{} $Repo 5000
                    }
                    Check ('WIN-03 ' + $barrierCase + ' junction creation') ($mk.ExitCode -eq 0 -and [IO.Directory]::Exists($parent))
                }
                [IO.File]::WriteAllBytes($barrier, [byte[]]@())
                $result = Wait-CapturedProcessAsync $handle 15000
                $handle = $null
                Check-Run ('WIN-03 ' + $barrierCase + ' reparse barrier run') $result
                Check ('WIN-03 ' + $barrierCase + ' blocks target write') (-not [IO.File]::Exists($target) -and -not [IO.File]::Exists((Join-Path $outside 'float.txt')))
            } finally {
                if ($null -ne $handle) { [IO.File]::WriteAllBytes($barrier, [byte[]]@()); [void](Wait-CapturedProcessAsync $handle 15000) }
                Remove-Item -LiteralPath $parent,$link,$barrier -Force -Recurse -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath (Join-Path $caseRoot 'parent-backup') -Force -Recurse -ErrorAction SilentlyContinue
            }
        }
    }

    $floatBashRoot = Join-Path $win03Root 'float-bash'
    [void][IO.Directory]::CreateDirectory($floatBashRoot)
    $floatBashTarget = Join-Path $floatBashRoot 'float.txt'
    $floatBashConfig = New-FloatConfig 'win03-float-bash' $floatBashTarget 'model ctx cost' '  |  ' @()
    $floatBashPs = Invoke-Float (Json $basePayload) $floatBashConfig @{}
    $floatBashPsBytes = Float-Bytes $floatBashTarget
    Remove-Item -LiteralPath $floatBashTarget -Force
    $floatBashRun = Invoke-BashStatusline (Json $basePayload) $floatBashConfig @{}
    Check-Run 'WIN-03 Bash float oracle' $floatBashRun
    $floatBashBytes = Float-Bytes $floatBashTarget
    $floatSame = $null -ne $floatBashPsBytes -and $null -ne $floatBashBytes -and $floatBashPsBytes.Length -eq $floatBashBytes.Length
    if ($floatSame) { for ($i=0; $i -lt $floatBashPsBytes.Length; $i++) { if ($floatBashPsBytes[$i] -ne $floatBashBytes[$i]) { $floatSame=$false; break } } }
    Check 'WIN-03 float bytes match Bash producer' $floatSame

    $emptyFloatTarget = Join-Path $win03Root 'empty-float.txt'
    $emptyFloatConfig = New-FloatConfig 'win03-float-empty' $emptyFloatTarget '' '|' @()
    $emptyFloatRun = Invoke-Float '{}' $emptyFloatConfig @{}
    Check-Run 'WIN-03 empty float' $emptyFloatRun
    $emptyFloatBytes = Float-Bytes $emptyFloatTarget
    Check 'WIN-03 empty float is exactly LF' ($null -ne $emptyFloatBytes -and $emptyFloatBytes.Length -eq 1 -and $emptyFloatBytes[0] -eq 10)

    # Authorization is depth/case sensitive while the default remains usable.
    foreach ($kind in @('included-exact','included-mixed','root-mixed')) {
        $homeCase = Join-Path $win03Root ('home-' + $kind)
        [void][IO.Directory]::CreateDirectory($homeCase)
        $targetA = Join-Path $win03Root ($kind + '-a.txt')
        $targetB = Join-Path $win03Root ($kind + '-b.txt')
        $include = Join-Path (Join-Path $TempRoot 'config') ($kind + '-include.conf')
        $authLines = @('VL_SEGMENTS=model','VL_CLOCK=off','VL_FLOAT=1','VL_FLOAT_SEGMENTS=model')
        if ($kind -eq 'included-exact') {
            Write-Utf8 $include ('VL_FLOAT_FILE=' + (Quote-FromConfigure $targetB) + "`n")
            $authLines += ('. ' + (Quote-FromConfigure $include))
            $authLines += ('VL_FLOAT_FILE=' + (Quote-FromConfigure $targetA))
        } elseif ($kind -eq 'included-mixed') {
            Write-Utf8 $include ('vl_float_file=' + (Quote-FromConfigure $targetB) + "`n")
            $authLines += ('. ' + (Quote-FromConfigure $include))
            $authLines += ('VL_FLOAT_FILE=' + (Quote-FromConfigure $targetA))
        } else {
            $authLines += ('vl_float_file=' + (Quote-FromConfigure $targetB))
        }
        $authConfig = New-Config ('win03-auth-' + $kind) $authLines
        $authRun = Invoke-Float (Json $basePayload) $authConfig @{ HOME=$homeCase; USERPROFILE=$homeCase }
        Check-Run ('WIN-03 float authorization ' + $kind) $authRun
        if ($kind -ne 'root-mixed') { Check ('WIN-03 ' + $kind + ' root target wins') ([IO.File]::Exists($targetA) -and -not [IO.File]::Exists($targetB)) }
        else { Check ('WIN-03 root mixed key is no-op') (-not [IO.File]::Exists($targetB) -and [IO.File]::Exists((Join-Path $homeCase '.claude\coralline\float.txt'))) }
    }
    $invalidFloatCases = @(
        [pscustomobject]@{ Name='empty'; Value="''" },
        [pscustomobject]@{ Name='unc'; Value="'\\localhost\share\float.txt'" },
        [pscustomobject]@{ Name='device'; Value="'\\?\C:\float.txt'" },
        [pscustomobject]@{ Name='ads'; Value="'carrier.txt:float'" },
        [pscustomobject]@{ Name='dos'; Value="'CON.txt'" },
        [pscustomobject]@{ Name='trailing'; Value="'bad. '" }
    )
    foreach ($bad in $invalidFloatCases) {
        $homeBad = Join-Path $win03Root ('home-bad-' + $bad.Name)
        [void][IO.Directory]::CreateDirectory($homeBad)
        $badConfig = New-Config ('win03-float-bad-' + $bad.Name) @('VL_SEGMENTS=model','VL_CLOCK=off','VL_FLOAT=1','VL_FLOAT_SEGMENTS=model',('VL_FLOAT_FILE=' + $bad.Value))
        $badRun = Invoke-Float (Json $basePayload) $badConfig @{ HOME=$homeBad; USERPROFILE=$homeBad }
        Check-Run ('WIN-03 invalid float path ' + $bad.Name) $badRun
        Check ('WIN-03 invalid float path ' + $bad.Name + ' skips default write') (-not [IO.File]::Exists((Join-Path $homeBad '.claude\coralline\float.txt')))
    }

    $collisionRoot = Join-Path $win03Root 'dormant-collision'
    [void][IO.Directory]::CreateDirectory($collisionRoot)
    $collisionBase = Join-Path $collisionRoot 'burn.tsv'
    $collisionConfig = New-Config 'win03-dormant-state-collision' @('VL_SEGMENTS=model','VL_CLOCK=off','VL_FLOAT=1','VL_FLOAT_SEGMENTS=model',('VL_FLOAT_FILE=' + (Quote-FromConfigure $collisionBase)),('BURN_FILE=' + (Quote-FromConfigure $collisionBase)))
    $collisionRun = Invoke-Float (Json $basePayload) $collisionConfig @{}
    Check-Run 'WIN-03 dormant state collision' $collisionRun
    Check 'WIN-03 dormant state collision creates no float or state file' (-not [IO.File]::Exists($collisionBase))

    $longTarget = Join-Path $win03Root 'long.txt'
    $longSegments = 'model ' + ('x' * 4091)
    $longConfig = New-FloatConfig 'win03-float-segment-bound' $longTarget $longSegments '|' @()
    $longRun = Invoke-Float (Json $basePayload) $longConfig @{}
    Check-Run 'WIN-03 float segment bound' $longRun
    Check 'WIN-03 overlong float segment list skips write' (-not [IO.File]::Exists($longTarget))
    $sepTarget = Join-Path $win03Root 'sep.txt'
    $sepConfig = New-FloatConfig 'win03-float-separator-bound' $sepTarget 'model' ('x' * 257) @()
    $sepRun = Invoke-Float (Json $basePayload) $sepConfig @{}
    Check-Run 'WIN-03 float separator bound' $sepRun
    Check 'WIN-03 overlong float separator skips write' (-not [IO.File]::Exists($sepTarget))

    Check 'WIN-03 source caches stash/node/python probes' ($source.Contains('$script:StashCacheSet') -and $source.Contains('$script:NodeCacheSet') -and $source.Contains('$script:PythonCacheSet'))
    Check 'WIN-03 state collision derivation is outside state gates' ($source.IndexOf('$AllStatePaths') -lt $source.IndexOf('$BurnStateGate'))
    Assert-NoUnexpectedResidue $win03Root 'WIN-03 float matrix'

} finally {
    try { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction Stop } catch { }
    $cleanupOk = -not (Test-Path -LiteralPath $TempRoot)
}

Check 'finally removes the harness temp root' $cleanupOk
Write-Output "SUMMARY pass=$script:Pass fail=$script:Fail blocked=$script:Blocked"
if ($script:Fail -ne 0) { exit 1 }
exit 0
