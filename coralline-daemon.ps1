#Requires -Version 5.1
# coralline-daemon.ps1 - persistent render server for statusline.ps1.
# Started automatically by the client when unreachable; never meant to be
# launched directly by the user. Safe to kill at any time - the client
# always has a full cold-start fallback, so a missing/dead daemon degrades
# performance, never correctness.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$here = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
$debugLog = $null
if ([string]$env:CORALLINE_DAEMON_DEBUG -eq '1') {
    $debugLog = [System.IO.Path]::Combine($here, 'daemon-debug.log')
}
function Write-DaemonLog([string]$Message) {
    if ($null -eq $debugLog) { return }
    try {
        $line = "[{0:yyyy-MM-dd HH:mm:ss.fff}] {1}`r`n" -f [DateTime]::UtcNow, $Message
        [System.IO.File]::AppendAllText($debugLog, $line)
    } catch { }
}

# Per-user pipe/mutex names, matching the hashing convention already used for
# the git-status cache filenames - a stable per-user identifier without
# leaking the raw home-directory path into a global (all-users) namespace.
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
$mutexName = "Local\coralline-statusline-daemon-$idHex"

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-DaemonLog "another daemon instance already holds the mutex, exiting"
    exit 0
}

. (Join-Path $here 'coralline-core.ps1')
. Initialize-CorallineRuntime
$script:LastConfigMtimeCheck = [DateTime]::MinValue
$script:LastConfigMtime = $null
function Get-ConfigMtimeSafe {
    if ([string]::IsNullOrEmpty($ConfigPath)) { return $null }
    try { return [IO.File]::GetLastWriteTimeUtc($ConfigPath) } catch { return $null }
}
$script:LastConfigMtime = Get-ConfigMtimeSafe

# Config rarely changes mid-session, and a stat call on this sandbox's
# filesystem is not free, so this is checked on a cooldown rather than every
# request - a live edit takes effect within this window, not instantly.
function Test-ConfigReload {
    $now = [DateTime]::UtcNow
    if (($now - $script:LastConfigMtimeCheck).TotalSeconds -lt 5) { return }
    $script:LastConfigMtimeCheck = $now
    $current = Get-ConfigMtimeSafe
    $changed = $false
    if ($null -eq $current -and $null -ne $script:LastConfigMtime) { $changed = $true }
    elseif ($null -ne $current -and $current -ne $script:LastConfigMtime) { $changed = $true }
    if ($changed) {
        Write-DaemonLog "config changed, reloading"
        . Initialize-CorallineRuntime
        $script:LastConfigMtime = Get-ConfigMtimeSafe
    }
}

$idleTimeoutMs = 30 * 60 * 1000
$maxRequestBytes = 4194304

Write-DaemonLog "daemon ready, pid=$PID, pipe=$pipeName"

$running = $true
while ($running) {
    Test-ConfigReload

    $server = $null
    try {
        $server = New-Object System.IO.Pipes.NamedPipeServerStream(
            $pipeName, [System.IO.Pipes.PipeDirection]::InOut, 8,
            [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous
        )
    } catch {
        Write-DaemonLog "failed to create pipe instance: $_"
        Start-Sleep -Milliseconds 500
        continue
    }

    $asyncResult = $server.BeginWaitForConnection($null, $null)
    $signaled = $asyncResult.AsyncWaitHandle.WaitOne($idleTimeoutMs)
    if (-not $signaled) {
        $server.Dispose()
        $running = $false
        break
    }

    try {
        $server.EndWaitForConnection($asyncResult)
        $reader = New-Object System.IO.BinaryReader($server)
        $mode = $reader.ReadInt32()
        $len = $reader.ReadInt32()
        if ($len -lt 0 -or $len -gt $maxRequestBytes) {
            Write-DaemonLog "rejected request with invalid length=$len"
        } else {
            $bytes = $reader.ReadBytes($len)
            $rawInputReq = [System.Text.Encoding]::UTF8.GetString($bytes)
            $isSubagent = ($mode -eq 1)

            $sw = $null
            if ($null -ne $debugLog) { $sw = [System.Diagnostics.Stopwatch]::StartNew() }
            $response = Invoke-StatuslineRequest -RawInputParam $rawInputReq -SubagentModeParam $isSubagent
            if ($null -eq $response) { $response = '' }
            if ($null -ne $sw) { Write-DaemonLog ("handled request in {0:F2} ms, mode={1}" -f $sw.Elapsed.TotalMilliseconds, $mode) }

            $respBytes = [System.Text.Encoding]::UTF8.GetBytes($response)
            $writer = New-Object System.IO.BinaryWriter($server)
            $writer.Write([int]$respBytes.Length)
            $writer.Write($respBytes)
            $server.Flush()
            try { $server.WaitForPipeDrain() } catch { }
        }
    } catch {
        Write-DaemonLog "request handling error: $_"
    } finally {
        if ($null -ne $server) { $server.Dispose() }
    }
}

$mutex.ReleaseMutex()
Write-DaemonLog "idle-exit, pid=$PID"
