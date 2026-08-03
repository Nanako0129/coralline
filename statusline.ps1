#Requires -Version 5.1
<#
  coralline statusline entry point (daemon-backed).

  Tries a persistent render daemon over a local named pipe first; if it is
  unreachable within a short timeout, starts one in the background for next
  time and falls back to rendering this one call in-process the same way the
  daemon (and the original single-file script) would - so a dead/missing/
  broken daemon degrades performance only, never correctness or output.
#>

$__sw = [System.Diagnostics.Stopwatch]::StartNew()
$here = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
$SubagentMode = $args.Count -gt 0 -and [string]$args[0] -ceq '--subagent'

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$LenientUtf8 = New-Object System.Text.UTF8Encoding($false, $false)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$InputStream = [Console]::OpenStandardInput()

$inputCap = 4194304
$inputBytes = New-Object byte[] ($inputCap + 1)
$inputLength = 0
try {
    while ($inputLength -lt $inputBytes.Length) {
        $read = $InputStream.Read($inputBytes, $inputLength, $inputBytes.Length - $inputLength)
        if ($read -le 0) { break }
        $inputLength += $read
    }
} catch { $inputLength = 0 }
if ($inputLength -gt $inputCap) {
    if ($SubagentMode) { [Environment]::Exit(0) }
    $inputLength = 0
}

$inputStart = 0
if ($inputLength -ge 3 -and $inputBytes[0] -eq 0xEF -and $inputBytes[1] -eq 0xBB -and $inputBytes[2] -eq 0xBF) { $inputStart = 3 }

try {
    $rawInput = $StrictUtf8.GetString($inputBytes, $inputStart, $inputLength - $inputStart)
} catch {
    try { $rawInput = $LenientUtf8.GetString($inputBytes, $inputStart, $inputLength - $inputStart) }
    catch { $rawInput = '' }
}

$OutputStream = [Console]::OpenStandardOutput()
$OutputWriter = New-Object System.IO.StreamWriter($OutputStream, $Utf8NoBom, 4096, $false)
$OutputWriter.NewLine = "`n"
$OutputWriter.AutoFlush = $true
$OutputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom

# Same per-user identifier derivation as coralline-daemon.ps1 - must match
# exactly, or the client will never find its own daemon.
$homeForId = [string]$HOME
if ([string]::IsNullOrEmpty($homeForId)) { $homeForId = [Environment]::GetFolderPath('UserProfile') }
$idHex = ''
try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($homeForId.ToLowerInvariant()))
        $sb = New-Object System.Text.StringBuilder
        foreach ($b in $bytes) { [void]$sb.Append($b.ToString('x2')) }
        $idHex = $sb.ToString().Substring(0, 16)
    } finally { $sha.Dispose() }
} catch { $idHex = 'fallback' }
$pipeName = "coralline-statusline-$idHex"

$mode = 0
if ($SubagentMode) { $mode = 1 }
$connected = $false
$response = $null
try {
    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $client.Connect(200)
    $reqBytes = [System.Text.Encoding]::UTF8.GetBytes($rawInput)
    $writer = New-Object System.IO.BinaryWriter($client)
    $writer.Write([int]$mode)
    $writer.Write([int]$reqBytes.Length)
    $writer.Write($reqBytes)
    $client.Flush()
    $reader = New-Object System.IO.BinaryReader($client)
    $len = $reader.ReadInt32()
    if ($len -ge 0 -and $len -le $inputCap) {
        $bytes = $reader.ReadBytes($len)
        $response = [System.Text.Encoding]::UTF8.GetString($bytes)
        $connected = $true
    }
    $client.Dispose()
} catch { $connected = $false }

if ($connected -and $null -ne $response) {
    $OutputWriter.Write($response)
    $OutputWriter.Flush()
} else {
    try {
        Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'coralline-daemon.ps1') `
            -WindowStyle Hidden
    } catch { }

    . (Join-Path $here 'coralline-core.ps1')
    . Initialize-CorallineRuntime
    $response = Invoke-StatuslineRequest -RawInputParam $rawInput -SubagentModeParam $SubagentMode
    if ($null -eq $response) { $response = '' }
    $OutputWriter.Write($response)
    $OutputWriter.Flush()
}
