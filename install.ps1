#Requires -Version 5.1
<#
  Native Windows PowerShell installer for coralline.

  Remote mode resolves one GitHub ref to a commit, then downloads only the
  renderer and the shipped themes from that commit. Local mode is hermetic and
  requires every destination explicitly.
#>

[CmdletBinding(DefaultParameterSetName = 'Remote')]
param(
    [Parameter(ParameterSetName = 'Remote')]
    [ValidateNotNullOrEmpty()]
    [string]$Repo = 'Nanako0129/coralline',

    [Parameter(ParameterSetName = 'Remote')]
    [ValidateNotNullOrEmpty()]
    [string]$Ref = 'main',

    [Parameter(Mandatory = $true, ParameterSetName = 'Local')]
    [ValidateNotNullOrEmpty()]
    [string]$SourceDirectory,

    [Parameter(Mandatory = $true, ParameterSetName = 'Local')]
    [ValidateNotNullOrEmpty()]
    [string]$InstallRoot,

    [Parameter(Mandatory = $true, ParameterSetName = 'Local')]
    [ValidateNotNullOrEmpty()]
    [string]$SettingsPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:MaxSettingsBytes = 8MB
$script:MaxApiBytes = 1MB
$script:MaxRuntimeBytes = 2MB
$script:MaxThemeBytes = 256KB
$script:MaxJsonDepth = 128
$script:ApiOrigin = 'https://api.github.com'
$script:RawOrigin = 'https://raw.githubusercontent.com'
$script:LocalMode = $PSCmdlet.ParameterSetName -ceq 'Local'
$script:ManagedFiles = @(
    'statusline.ps1',
    'themes\catppuccin-mocha.conf',
    'themes\claude-coral.conf',
    'themes\dracula.conf',
    'themes\gruvbox-dark.conf',
    'themes\lunar-pink.conf',
    'themes\mono.conf',
    'themes\morning-haze.conf',
    'themes\nord.conf',
    'themes\reverie.conf',
    'themes\tokyo-night.conf'
)

function Test-HasControlCharacter([string]$Value) {
    if ($null -eq $Value) { return $false }
    foreach ($character in $Value.ToCharArray()) {
        $number = [int]$character
        if ($number -lt 0x20 -or ($number -ge 0x7f -and $number -le 0x9f)) {
            return $true
        }
    }
    return $false
}

function Assert-SafePathSegments([string]$FullPath) {
    $root = [System.IO.Path]::GetPathRoot($FullPath)
    $tail = $FullPath.Substring($root.Length)
    foreach ($segment in $tail.Split(@([char]'\', [char]'/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        if ($segment.EndsWith('.', [System.StringComparison]::Ordinal) -or
            $segment.EndsWith(' ', [System.StringComparison]::Ordinal)) {
            throw "path segments may not end in a dot or space: $FullPath"
        }
        $base = $segment.Split('.')[0]
        if ($base -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw "reserved device name in path: $FullPath"
        }
    }
}

function Resolve-CanonicalLocalPath([string]$Path, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label is empty" }
    if (Test-HasControlCharacter $Path) { throw "$Label contains a control character" }
    if ($Path.IndexOfAny([char[]]@('"', '<', '>', '|', '?', '*')) -ge 0) {
        throw "$Label contains a character Windows paths cannot safely represent"
    }
    if ($Path.StartsWith(([string][char]92 + [char]92), [System.StringComparison]::Ordinal) -or
        $Path.StartsWith('//', [System.StringComparison]::Ordinal)) {
        throw "$Label must not use a UNC or device path"
    }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { throw "$Label must be absolute" }
    if ($Path.Length -lt 3 -or $Path[1] -ne ':' -or -not [char]::IsLetter($Path[0]) -or
        ($Path[2] -ne '\' -and $Path[2] -ne '/')) {
        throw "$Label must be on a local drive"
    }
    if ($Path.IndexOf(':', 2) -ge 0) { throw "$Label must not contain an alternate data stream" }

    try { $full = [System.IO.Path]::GetFullPath($Path).Replace('/', '\') }
    catch { throw "$Label is not a valid canonical path: $($_.Exception.Message)" }
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($root -notmatch '^[A-Za-z]:\\$') { throw "$Label must be on a local drive" }

    try {
        $drive = New-Object System.IO.DriveInfo($root)
        if ($drive.DriveType -notin @(
            [System.IO.DriveType]::Fixed,
            [System.IO.DriveType]::Removable,
            [System.IO.DriveType]::Ram
        )) {
            throw "$Label must not be on a network or virtual provider drive"
        }
    } catch {
        if ($_.Exception.Message -like "$Label *") { throw }
        throw "$Label drive cannot be inspected: $($_.Exception.Message)"
    }

    Assert-SafePathSegments $full
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\') }
    return $full
}

function Assert-NoReparsePath([string]$FullPath, [string]$Label) {
    $root = [System.IO.Path]::GetPathRoot($FullPath)
    $current = $root
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label drive root is a reparse point"
    }

    $tail = $FullPath.Substring($root.Length)
    foreach ($segment in $tail.Split(@([char]'\'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $current = [System.IO.Path]::Combine($current, $segment)
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { break }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label contains an existing reparse point: $current"
        }
    }
}

function Assert-SafeExistingFile([string]$Path, [string]$Label) {
    Assert-NoReparsePath $Path $Label
    if ([System.IO.Directory]::Exists($Path)) { throw "$Label must be a file: $Path" }
}

function Assert-SafeExistingDirectory([string]$Path, [string]$Label) {
    Assert-NoReparsePath $Path $Label
    if ([System.IO.File]::Exists($Path)) { throw "$Label must be a directory: $Path" }
}

function Ensure-SafeDirectory([string]$Path, [string]$Label) {
    Assert-NoReparsePath $Path $Label
    if ([System.IO.File]::Exists($Path)) { throw "$Label is occupied by a file: $Path" }
    if (-not [System.IO.Directory]::Exists($Path)) {
        [void][System.IO.Directory]::CreateDirectory($Path)
    }
    Assert-NoReparsePath $Path $Label
    if (-not [System.IO.Directory]::Exists($Path)) { throw "failed to create ${Label}: $Path" }
}

function Test-PathsOverlap([string]$First, [string]$Second) {
    if ($First.Equals($Second, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $firstPrefix = $First.TrimEnd('\') + '\'
    $secondPrefix = $Second.TrimEnd('\') + '\'
    return (
        $First.StartsWith($secondPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $Second.StartsWith($firstPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Assert-DisjointPaths([object[]]$Entries) {
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        for ($j = $i + 1; $j -lt $Entries.Count; $j++) {
            if (Test-PathsOverlap ([string]$Entries[$i].Path) ([string]$Entries[$j].Path)) {
                throw (
                    '{0} and {1} must not be equal, ancestors, or descendants: {2} ; {3}' -f
                    $Entries[$i].Label, $Entries[$j].Label, $Entries[$i].Path, $Entries[$j].Path
                )
            }
        }
    }
}

function Assert-CommandPath([string]$Path, [string]$Label) {
    if (Test-HasControlCharacter $Path) { throw "$Label contains a control character" }
    if ($Path.IndexOf('"') -ge 0 -or $Path.IndexOf('%') -ge 0 -or $Path.IndexOf('!') -ge 0) {
        throw "$Label contains a character that cannot survive the Claude Code cmd.exe boundary"
    }
    Assert-NoReparsePath $Path $Label
}

function Get-SafeTreeInventory([string]$Root, [string]$Label) {
    Assert-NoReparsePath $Root $Label
    if (-not [System.IO.Directory]::Exists($Root)) {
        return ,([pscustomobject]@{ Files = [string[]]@(); Directories = [string[]]@() })
    }

    $files = New-Object 'System.Collections.Generic.List[string]'
    $directories = New-Object 'System.Collections.Generic.List[string]'
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $attributes = [System.IO.File]::GetAttributes($entry)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label contains a reparse point: $entry"
            }
            $relative = $entry.Substring($Root.Length).TrimStart('\').Replace('/', '\')
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $directories.Add($relative)
                $queue.Enqueue($entry)
            } else {
                $files.Add($relative)
            }
        }
    }
    return ,([pscustomobject]@{
        Files = [string[]]$files.ToArray()
        Directories = [string[]]$directories.ToArray()
    })
}

function Remove-SafeInstallerDirectory([string]$Path, [string]$ExpectedPath, [string]$Label) {
    $canonical = Resolve-CanonicalLocalPath $Path $Label
    if (-not $canonical.Equals($ExpectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to clean an unexpected ${Label}: $canonical"
    }
    if (-not [System.IO.Directory]::Exists($canonical)) {
        if ([System.IO.File]::Exists($canonical)) { throw "$Label became a file; refusing cleanup" }
        return
    }
    [void](Get-SafeTreeInventory $canonical $Label)
    [System.IO.Directory]::Delete($canonical, $true)
}

function Remove-SafeInstallerFile([string]$Path, [string]$ExpectedPath, [string]$Label) {
    $canonical = Resolve-CanonicalLocalPath $Path $Label
    if (-not $canonical.Equals($ExpectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to clean an unexpected ${Label}: $canonical"
    }
    Assert-NoReparsePath $canonical $Label
    if ([System.IO.Directory]::Exists($canonical)) { throw "$Label became a directory; refusing cleanup" }
    if ([System.IO.File]::Exists($canonical)) { [System.IO.File]::Delete($canonical) }
}

function Test-FilesEqual([string]$First, [string]$Second) {
    $firstInfo = New-Object System.IO.FileInfo($First)
    $secondInfo = New-Object System.IO.FileInfo($Second)
    if ($firstInfo.Length -ne $secondInfo.Length) { return $false }

    $firstStream = $null
    $secondStream = $null
    try {
        $firstStream = [System.IO.File]::Open($First, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $secondStream = [System.IO.File]::Open($Second, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $firstBuffer = New-Object byte[] 8192
        $secondBuffer = New-Object byte[] 8192
        while ($true) {
            $firstRead = $firstStream.Read($firstBuffer, 0, $firstBuffer.Length)
            $secondRead = $secondStream.Read($secondBuffer, 0, $secondBuffer.Length)
            if ($firstRead -ne $secondRead) { return $false }
            if ($firstRead -eq 0) { return $true }
            for ($i = 0; $i -lt $firstRead; $i++) {
                if ($firstBuffer[$i] -ne $secondBuffer[$i]) { return $false }
            }
        }
    } finally {
        if ($null -ne $secondStream) { $secondStream.Dispose() }
        if ($null -ne $firstStream) { $firstStream.Dispose() }
    }
}

function Test-ByteArraysEqual([byte[]]$First, [byte[]]$Second) {
    if ($First.Length -ne $Second.Length) { return $false }
    for ($i = 0; $i -lt $First.Length; $i++) {
        if ($First[$i] -ne $Second[$i]) { return $false }
    }
    return $true
}

function Read-BoundedSharedFileBytes(
    [string]$Path,
    [long]$MaximumBytes,
    [string]$Label
) {
    Assert-NoReparsePath $Path $Label
    $sharing = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        $sharing
    )
    try {
        $length = $stream.Length
        if ($length -gt $MaximumBytes) {
            throw "$Label exceeds the $MaximumBytes byte limit"
        }
        $bytes = New-Object byte[] ([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { throw "$Label changed while being read" }
            $offset += $read
        }
        if ($stream.Length -ne $length) { throw "$Label changed while being read" }
        return ,$bytes
    } finally {
        $stream.Dispose()
    }
}

function Copy-BoundedLocalFile([string]$Source, [string]$Destination, [long]$MaximumBytes, [string]$Label) {
    Assert-NoReparsePath $Source $Label
    if (-not [System.IO.File]::Exists($Source)) { throw "$Label is missing: $Source" }
    $length = (New-Object System.IO.FileInfo($Source)).Length
    if ($length -gt $MaximumBytes) { throw "$Label exceeds the $MaximumBytes byte limit" }
    [System.IO.File]::Copy($Source, $Destination, $false)
}

function Assert-ValidRepoAndRef([string]$Repository, [string]$Revision) {
    if ($Repository -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$') {
        throw 'Repo must be a GitHub owner/repository name'
    }
    if ($Revision.Length -gt 200 -or
        $Revision -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or
        $Revision.Contains('..') -or
        $Revision.Contains('//') -or
        $Revision.Contains('@{') -or
        $Revision.EndsWith('/', [System.StringComparison]::Ordinal) -or
        $Revision.EndsWith('.', [System.StringComparison]::Ordinal) -or
        $Revision -match '(?i)(^|/)[^/]*\.lock($|/)') {
        throw 'Ref contains characters or a shape that is unsafe for a GitHub revision'
    }
}

function Read-BoundedHttpsBytes([uri]$Uri, [long]$MaximumBytes, [string]$Label) {
    if ($Uri.Scheme -cne 'https') { throw "$Label must use HTTPS" }
    if ($Uri.Host -cne 'api.github.com' -and $Uri.Host -cne 'raw.githubusercontent.com') {
        throw "$Label uses an unexpected host: $($Uri.Host)"
    }
    if (-not [string]::IsNullOrEmpty($Uri.UserInfo) -or -not [string]::IsNullOrEmpty($Uri.Query) -or
        -not [string]::IsNullOrEmpty($Uri.Fragment)) {
        throw "$Label URI contains unexpected authority or suffix data"
    }

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $false
    $request.Timeout = 15000
    $request.ReadWriteTimeout = 15000
    $request.UserAgent = 'coralline-install.ps1'
    $response = $null
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        if ($response.StatusCode -ne [System.Net.HttpStatusCode]::OK) {
            throw "$Label returned HTTP $([int]$response.StatusCode)"
        }
        if ($response.ResponseUri.AbsoluteUri -cne $Uri.AbsoluteUri) {
            throw "$Label redirected to an unexpected URI"
        }
        if ($response.ContentLength -gt $MaximumBytes) {
            throw "$Label Content-Length exceeds the $MaximumBytes byte limit"
        }

        $input = $response.GetResponseStream()
        $memory = New-Object System.IO.MemoryStream
        try {
            $buffer = New-Object byte[] 8192
            $total = 0L
            while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $total += $read
                if ($total -gt $MaximumBytes) {
                    throw "$Label stream exceeds the $MaximumBytes byte limit"
                }
                $memory.Write($buffer, 0, $read)
            }
            if ($response.ContentLength -ge 0 -and $total -ne $response.ContentLength) {
                throw "$Label ended before its declared Content-Length"
            }
            return ,$memory.ToArray()
        } finally {
            if ($null -ne $input) { $input.Dispose() }
            $memory.Dispose()
        }
    } catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            $statusResponse = [System.Net.HttpWebResponse]$_.Exception.Response
            try { throw "$Label returned HTTP $([int]$statusResponse.StatusCode)" }
            finally { $statusResponse.Dispose() }
        }
        throw "$Label download failed: $($_.Exception.Message)"
    } finally {
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Resolve-GitHubCommit([string]$Repository, [string]$Revision) {
    $parts = $Repository.Split('/')
    $owner = [uri]::EscapeDataString($parts[0])
    $name = [uri]::EscapeDataString($parts[1])
    $encodedRef = [uri]::EscapeDataString($Revision)
    $uri = New-Object uri("$($script:ApiOrigin)/repos/$owner/$name/commits/$encodedRef")
    $bytes = Read-BoundedHttpsBytes $uri $script:MaxApiBytes 'GitHub commit resolution'
    try { $text = $script:StrictUtf8.GetString($bytes) }
    catch { throw "GitHub commit response is not strict UTF-8: $($_.Exception.Message)" }
    try { $payload = $text | ConvertFrom-Json }
    catch { throw "GitHub commit response is not valid JSON: $($_.Exception.Message)" }
    if ($null -eq $payload -or $payload.PSObject.Properties.Name -notcontains 'sha') {
        throw 'GitHub commit response has no sha'
    }
    $sha = [string]$payload.sha
    if ($sha -cnotmatch '^[0-9a-f]{40}$') { throw 'GitHub returned an invalid commit sha' }
    return $sha
}

function Get-RawFileUri([string]$Repository, [string]$Commit, [string]$RelativePath) {
    $parts = $Repository.Split('/')
    $segments = New-Object 'System.Collections.Generic.List[string]'
    $segments.Add([uri]::EscapeDataString($parts[0]))
    $segments.Add([uri]::EscapeDataString($parts[1]))
    $segments.Add($Commit)
    foreach ($segment in $RelativePath.Replace('\', '/').Split('/')) {
        $segments.Add([uri]::EscapeDataString($segment))
    }
    return New-Object uri("$($script:RawOrigin)/$([string]::Join('/', $segments.ToArray()))")
}

function Write-BytesCreateNew([string]$Path, [byte[]]$Bytes) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Stage-RemotePayload([string]$Repository, [string]$Revision, [string]$StageRoot) {
    Assert-ValidRepoAndRef $Repository $Revision
    $oldProtocol = [System.Net.ServicePointManager]::SecurityProtocol
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $commit = $Revision
        if ($commit -cnotmatch '^[0-9a-f]{40}$') {
            $commit = Resolve-GitHubCommit $Repository $Revision
        }
        foreach ($relative in $script:ManagedFiles) {
            $maximum = $script:MaxThemeBytes
            if ($relative -ceq 'statusline.ps1') { $maximum = $script:MaxRuntimeBytes }
            $uri = Get-RawFileUri $Repository $commit $relative
            $bytes = Read-BoundedHttpsBytes $uri $maximum "coralline $relative"
            $destination = [System.IO.Path]::Combine($StageRoot, $relative)
            Ensure-SafeDirectory ([System.IO.Path]::GetDirectoryName($destination)) 'staging directory'
            Write-BytesCreateNew $destination $bytes
        }
        return $commit
    } finally {
        [System.Net.ServicePointManager]::SecurityProtocol = $oldProtocol
    }
}

function Stage-LocalPayload([string]$SourceRoot, [string]$StageRoot) {
    foreach ($relative in $script:ManagedFiles) {
        $maximum = $script:MaxThemeBytes
        if ($relative -ceq 'statusline.ps1') { $maximum = $script:MaxRuntimeBytes }
        $source = [System.IO.Path]::Combine($SourceRoot, $relative)
        $destination = [System.IO.Path]::Combine($StageRoot, $relative)
        Ensure-SafeDirectory ([System.IO.Path]::GetDirectoryName($destination)) 'staging directory'
        Copy-BoundedLocalFile $source $destination $maximum "source $relative"
    }
}

function Assert-ExpectedManagedInventory([string]$Root, [string]$Label) {
    $inventory = Get-SafeTreeInventory $Root $Label
    $files = @($inventory.Files | Sort-Object)
    $expectedFiles = @($script:ManagedFiles | Sort-Object)
    if ($files.Count -ne $expectedFiles.Count) { throw "$Label has an unexpected file inventory" }
    for ($i = 0; $i -lt $expectedFiles.Count; $i++) {
        if ($files[$i] -cne $expectedFiles[$i]) { throw "$Label has an unexpected file: $($files[$i])" }
    }
    $directories = @($inventory.Directories | Sort-Object)
    if ($directories.Count -ne 1 -or $directories[0] -cne 'themes') {
        throw "$Label has an unexpected directory inventory"
    }
}

function Assert-ValidManagedPayload([string]$Root, [string]$Label) {
    $runtime = [System.IO.Path]::Combine($Root, 'statusline.ps1')
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $runtime,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw "$Label statusline.ps1 failed PowerShell parsing: $($parseErrors[0].Message)"
    }

    foreach ($relative in $script:ManagedFiles) {
        $path = [System.IO.Path]::Combine($Root, $relative)
        if (-not [System.IO.File]::Exists($path)) { throw "$Label is missing $relative" }
        $length = (New-Object System.IO.FileInfo($path)).Length
        if ($relative -ceq 'statusline.ps1') {
            if ($length -eq 0 -or $length -gt $script:MaxRuntimeBytes) {
                throw "$Label statusline.ps1 has an invalid size"
            }
            continue
        }
        if ($length -eq 0 -or $length -gt $script:MaxThemeBytes) {
            throw "$Label theme has an invalid size: $relative"
        }
        try { $theme = $script:StrictUtf8.GetString([System.IO.File]::ReadAllBytes($path)) }
        catch { throw "$Label theme is not strict UTF-8: $relative" }
        if ($theme.IndexOf([char]0) -ge 0 -or
            $theme -notmatch '(?m)^# coralline theme:' -or
            $theme -notmatch '(?m)^VL_BG_DIR=' -or
            $theme -notmatch '(?m)^VL_FG_TEXT=') {
            throw "$Label theme failed content validation: $relative"
        }
    }
}

function Assert-ValidStagedPayload([string]$StageRoot) {
    Assert-ExpectedManagedInventory $StageRoot 'staged payload'
    Assert-ValidManagedPayload $StageRoot 'staged payload'
}

function Test-ManagedPayloadEqual([string]$StageRoot, [string]$InstalledRoot) {
    if (-not [System.IO.Directory]::Exists($InstalledRoot)) { return $false }
    foreach ($relative in $script:ManagedFiles) {
        $staged = [System.IO.Path]::Combine($StageRoot, $relative)
        $installed = [System.IO.Path]::Combine($InstalledRoot, $relative)
        Assert-NoReparsePath $installed "installed $relative"
        if (-not [System.IO.File]::Exists($installed)) { return $false }
        if (-not (Test-FilesEqual $staged $installed)) { return $false }
    }
    return $true
}

function Get-ManagedPayloadBytes([string]$Root) {
    $expected = @{}
    foreach ($relative in $script:ManagedFiles) {
        $path = [System.IO.Path]::Combine($Root, $relative)
        Assert-NoReparsePath $path "managed payload $relative"
        $expected[$relative] = [System.IO.File]::ReadAllBytes($path)
    }
    return ,$expected
}

function Assert-ManagedPayloadBytes([string]$Root, $Expected, [string]$Label) {
    foreach ($relative in $script:ManagedFiles) {
        $path = [System.IO.Path]::Combine($Root, $relative)
        Assert-SafeExistingFile $path "$Label $relative"
        if (-not [System.IO.File]::Exists($path)) {
            throw "$Label is missing $relative"
        }
        $maximum = $script:MaxThemeBytes
        if ($relative -ceq 'statusline.ps1') { $maximum = $script:MaxRuntimeBytes }
        $actual = Read-BoundedSharedFileBytes $path $maximum "$Label $relative"
        if (-not (Test-ByteArraysEqual $actual $Expected[$relative])) {
            throw "$Label changed concurrently: $relative"
        }
    }
}

function Skip-JsonWhitespace([string]$Text, [ref]$Index) {
    $i = [int]$Index.Value
    while ($i -lt $Text.Length) {
        $character = $Text[$i]
        if ($character -ne ' ' -and $character -ne "`t" -and
            $character -ne "`r" -and $character -ne "`n") {
            break
        }
        $i++
    }
    $Index.Value = $i
}

function Test-JsonWhitespaceOnly([string]$Text) {
    $index = 0
    Skip-JsonWhitespace $Text ([ref]$index)
    return $index -eq $Text.Length
}

function Read-JsonString([string]$Text, [ref]$Index) {
    $i = [int]$Index.Value
    if ($i -ge $Text.Length -or $Text[$i] -ne '"') { throw "expected JSON string at offset $i" }
    $i++
    $builder = New-Object System.Text.StringBuilder
    while ($i -lt $Text.Length) {
        $character = $Text[$i]
        if ($character -eq '"') {
            $Index.Value = $i + 1
            return $builder.ToString()
        }
        if ([int]$character -lt 0x20) { throw "unescaped control character in JSON string at offset $i" }
        if ($character -ne '\') {
            [void]$builder.Append($character)
            $i++
            continue
        }

        $i++
        if ($i -ge $Text.Length) { throw 'truncated JSON string escape' }
        $escape = $Text[$i]
        switch ($escape) {
            '"' { [void]$builder.Append('"'); $i++ }
            '\' { [void]$builder.Append('\'); $i++ }
            '/' { [void]$builder.Append('/'); $i++ }
            'b' { [void]$builder.Append([char]8); $i++ }
            'f' { [void]$builder.Append([char]12); $i++ }
            'n' { [void]$builder.Append([char]10); $i++ }
            'r' { [void]$builder.Append([char]13); $i++ }
            't' { [void]$builder.Append([char]9); $i++ }
            'u' {
                if ($i + 4 -ge $Text.Length) { throw 'truncated JSON unicode escape' }
                $hex = $Text.Substring($i + 1, 4)
                if ($hex -cnotmatch '^[0-9A-Fa-f]{4}$') { throw "invalid JSON unicode escape: \u$hex" }
                $code = [int]::Parse($hex, [System.Globalization.NumberStyles]::HexNumber, $script:Invariant)
                [void]$builder.Append([char]$code)
                $i += 5
            }
            default { throw "invalid JSON escape at offset $i" }
        }
    }
    throw 'truncated JSON string'
}

function Skip-JsonNumber([string]$Text, [ref]$Index) {
    $i = [int]$Index.Value
    if ($Text[$i] -eq '-') {
        $i++
        if ($i -ge $Text.Length) { throw 'truncated JSON number' }
    }
    if ($Text[$i] -eq '0') {
        $i++
        if ($i -lt $Text.Length -and $Text[$i] -ge '0' -and $Text[$i] -le '9') {
            throw "leading zero in JSON number at offset $i"
        }
    } elseif ($Text[$i] -ge '1' -and $Text[$i] -le '9') {
        do { $i++ } while ($i -lt $Text.Length -and $Text[$i] -ge '0' -and $Text[$i] -le '9')
    } else {
        throw "invalid JSON number at offset $i"
    }
    if ($i -lt $Text.Length -and $Text[$i] -eq '.') {
        $i++
        $fractionStart = $i
        while ($i -lt $Text.Length -and $Text[$i] -ge '0' -and $Text[$i] -le '9') { $i++ }
        if ($i -eq $fractionStart) { throw 'JSON fraction has no digits' }
    }
    if ($i -lt $Text.Length -and ($Text[$i] -eq 'e' -or $Text[$i] -eq 'E')) {
        $i++
        if ($i -lt $Text.Length -and ($Text[$i] -eq '+' -or $Text[$i] -eq '-')) { $i++ }
        $exponentStart = $i
        while ($i -lt $Text.Length -and $Text[$i] -ge '0' -and $Text[$i] -le '9') { $i++ }
        if ($i -eq $exponentStart) { throw 'JSON exponent has no digits' }
    }
    $Index.Value = $i
}

function Skip-JsonValue([string]$Text, [ref]$Index, [int]$Depth) {
    if ($Depth -gt $script:MaxJsonDepth) { throw "JSON nesting exceeds $($script:MaxJsonDepth)" }
    Skip-JsonWhitespace $Text $Index
    $i = [int]$Index.Value
    if ($i -ge $Text.Length) { throw 'truncated JSON value' }
    $character = $Text[$i]
    if ($character -eq '"') {
        [void](Read-JsonString $Text $Index)
        return
    }
    if ($character -eq '-' -or ($character -ge '0' -and $character -le '9')) {
        Skip-JsonNumber $Text $Index
        return
    }
    foreach ($literal in @('true', 'false', 'null')) {
        if ($Text.Length - $i -ge $literal.Length -and
            $Text.Substring($i, $literal.Length) -ceq $literal) {
            $Index.Value = $i + $literal.Length
            return
        }
    }
    if ($character -eq '[') {
        $i++
        $Index.Value = $i
        Skip-JsonWhitespace $Text $Index
        $i = [int]$Index.Value
        if ($i -lt $Text.Length -and $Text[$i] -eq ']') {
            $Index.Value = $i + 1
            return
        }
        while ($true) {
            Skip-JsonValue $Text $Index ($Depth + 1)
            Skip-JsonWhitespace $Text $Index
            $i = [int]$Index.Value
            if ($i -ge $Text.Length) { throw 'truncated JSON array' }
            if ($Text[$i] -eq ']') {
                $Index.Value = $i + 1
                return
            }
            if ($Text[$i] -ne ',') { throw "expected comma in JSON array at offset $i" }
            $Index.Value = $i + 1
            Skip-JsonWhitespace $Text $Index
        }
    }
    if ($character -eq '{') {
        $i++
        $Index.Value = $i
        Skip-JsonWhitespace $Text $Index
        $i = [int]$Index.Value
        if ($i -lt $Text.Length -and $Text[$i] -eq '}') {
            $Index.Value = $i + 1
            return
        }
        while ($true) {
            [void](Read-JsonString $Text $Index)
            Skip-JsonWhitespace $Text $Index
            $i = [int]$Index.Value
            if ($i -ge $Text.Length -or $Text[$i] -ne ':') {
                throw "expected colon in JSON object at offset $i"
            }
            $Index.Value = $i + 1
            Skip-JsonValue $Text $Index ($Depth + 1)
            Skip-JsonWhitespace $Text $Index
            $i = [int]$Index.Value
            if ($i -ge $Text.Length) { throw 'truncated JSON object' }
            if ($Text[$i] -eq '}') {
                $Index.Value = $i + 1
                return
            }
            if ($Text[$i] -ne ',') { throw "expected comma in JSON object at offset $i" }
            $Index.Value = $i + 1
            Skip-JsonWhitespace $Text $Index
        }
    }
    throw "invalid JSON value at offset $i"
}

function ConvertTo-JsonString([string]$Value) {
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        switch ([int]$character) {
            8 { [void]$builder.Append('\b') }
            9 { [void]$builder.Append('\t') }
            10 { [void]$builder.Append('\n') }
            12 { [void]$builder.Append('\f') }
            13 { [void]$builder.Append('\r') }
            34 { [void]$builder.Append('\"') }
            92 { [void]$builder.Append('\\') }
            default {
                if ([int]$character -lt 0x20) {
                    [void]$builder.Append(('\u{0:x4}' -f [int]$character))
                } else {
                    [void]$builder.Append($character)
                }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-SettingsPlan([string]$Path, [string]$DesiredValue) {
    $existed = [System.IO.File]::Exists($Path)
    $original = [byte[]]@()
    if ($existed) {
        $original = Read-BoundedSharedFileBytes (
            $Path
        ) $script:MaxSettingsBytes 'settings.json'
    }

    $offset = 0
    $hadBom = $false
    if ($original.Length -ge 3 -and $original[0] -eq 0xef -and
        $original[1] -eq 0xbb -and $original[2] -eq 0xbf) {
        $offset = 3
        $hadBom = $true
    }
    try { $text = $script:StrictUtf8.GetString($original, $offset, $original.Length - $offset) }
    catch { throw "settings.json is not strict UTF-8: $($_.Exception.Message)" }

    if (-not $existed -or $text.Length -eq 0 -or (Test-JsonWhitespaceOnly $text)) {
        $text = '{}'
    }

    $index = 0
    Skip-JsonWhitespace $text ([ref]$index)
    if ($index -ge $text.Length -or $text[$index] -ne '{') {
        throw 'settings.json must contain a top-level JSON object'
    }
    $index++
    Skip-JsonWhitespace $text ([ref]$index)
    $memberCount = 0
    $managedStart = -1
    $managedEnd = -1
    $closingBrace = -1
    if ($index -lt $text.Length -and $text[$index] -eq '}') {
        $closingBrace = $index
        $index++
    } else {
        while ($true) {
            $key = Read-JsonString $text ([ref]$index)
            Skip-JsonWhitespace $text ([ref]$index)
            if ($index -ge $text.Length -or $text[$index] -ne ':') {
                throw "expected colon after top-level JSON key at offset $index"
            }
            $index++
            Skip-JsonWhitespace $text ([ref]$index)
            $valueStart = $index
            Skip-JsonValue $text ([ref]$index) 1
            $valueEnd = $index
            if ($key -ceq 'statusLine') {
                if ($managedStart -ge 0) { throw 'settings.json contains duplicate exact-case statusLine members' }
                $managedStart = $valueStart
                $managedEnd = $valueEnd
            }
            $memberCount++
            Skip-JsonWhitespace $text ([ref]$index)
            if ($index -ge $text.Length) { throw 'truncated top-level JSON object' }
            if ($text[$index] -eq '}') {
                $closingBrace = $index
                $index++
                break
            }
            if ($text[$index] -ne ',') {
                throw "expected comma after top-level JSON member at offset $index"
            }
            $index++
            Skip-JsonWhitespace $text ([ref]$index)
        }
    }
    Skip-JsonWhitespace $text ([ref]$index)
    if ($index -ne $text.Length) { throw "unexpected data after top-level JSON object at offset $index" }

    if ($managedStart -ge 0) {
        $updated = $text.Substring(0, $managedStart) + $DesiredValue + $text.Substring($managedEnd)
    } else {
        $prefix = ''
        if ($memberCount -gt 0) { $prefix = ',' }
        $insertion = $prefix + '"statusLine":' + $DesiredValue
        $updated = $text.Substring(0, $closingBrace) + $insertion + $text.Substring($closingBrace)
    }
    $contentBytes = $script:Utf8NoBom.GetBytes($updated)
    if ($hadBom) {
        $updatedBytes = New-Object byte[] ($contentBytes.Length + 3)
        $updatedBytes[0] = 0xef
        $updatedBytes[1] = 0xbb
        $updatedBytes[2] = 0xbf
        [System.Array]::Copy($contentBytes, 0, $updatedBytes, 3, $contentBytes.Length)
    } else {
        $updatedBytes = $contentBytes
    }
    if ($updatedBytes.LongLength -gt $script:MaxSettingsBytes) {
        throw "updated settings.json exceeds the $($script:MaxSettingsBytes) byte limit"
    }
    $changed = -not (Test-ByteArraysEqual $original $updatedBytes)
    return ,([pscustomobject]@{
        Existed = $existed
        OriginalBytes = $original
        UpdatedBytes = $updatedBytes
        Changed = $changed
    })
}

function Assert-SettingsBytes([string]$Path, [byte[]]$Expected, [string]$Label) {
    Assert-SafeExistingFile $Path $Label
    if (-not [System.IO.File]::Exists($Path)) { throw "$Label is missing" }
    $actual = Read-BoundedSharedFileBytes $Path $script:MaxSettingsBytes $Label
    if (-not (Test-ByteArraysEqual $actual $Expected)) {
        throw "$Label changed concurrently"
    }
}

function Restore-SettingsOriginal(
    [string]$Path,
    $Plan,
    [string]$RestoreTemporaryPath,
    [string]$FailedTemporaryPath
) {
    if ($Plan.Existed) {
        if (-not [System.IO.File]::Exists($Path)) {
            throw 'settings target disappeared after installer mutation; refusing rollback'
        }
        Assert-NoReparsePath $Path 'settings rollback target'
        $current = Read-BoundedSharedFileBytes (
            $Path
        ) $script:MaxSettingsBytes 'settings rollback target'
        if (Test-ByteArraysEqual $current $Plan.OriginalBytes) {
            return
        }
        if (-not (Test-ByteArraysEqual $current $Plan.UpdatedBytes)) {
            throw 'settings target no longer contains installer bytes; refusing to overwrite concurrent changes'
        }

        if (-not [System.IO.File]::Exists($RestoreTemporaryPath)) {
            throw "settings rollback source is missing: $RestoreTemporaryPath"
        }
        Assert-NoReparsePath $RestoreTemporaryPath 'settings rollback temporary file'
        if (-not (Test-ByteArraysEqual (
            Read-BoundedSharedFileBytes (
                $RestoreTemporaryPath
            ) $script:MaxSettingsBytes 'settings rollback temporary file'
        ) $Plan.OriginalBytes)) {
            throw "settings rollback source contains external bytes retained at $RestoreTemporaryPath"
        }
        if ([System.IO.File]::Exists($FailedTemporaryPath)) {
            throw "settings rollback recovery path already exists: $FailedTemporaryPath"
        }
        [System.IO.File]::Replace($RestoreTemporaryPath, $Path, $FailedTemporaryPath)
        Assert-NoReparsePath $FailedTemporaryPath 'failed settings rollback backup'
        if (-not (Test-ByteArraysEqual (
            Read-BoundedSharedFileBytes (
                $FailedTemporaryPath
            ) $script:MaxSettingsBytes 'failed settings rollback backup'
        ) $Plan.UpdatedBytes)) {
            throw "settings changed concurrently during rollback; recovery copy retained at $FailedTemporaryPath"
        }
        if (-not (Test-ByteArraysEqual (
            Read-BoundedSharedFileBytes (
                $Path
            ) $script:MaxSettingsBytes 'settings rollback target'
        ) $Plan.OriginalBytes)) {
            throw 'settings rollback verification failed'
        }
    } elseif ([System.IO.File]::Exists($Path)) {
        Assert-NoReparsePath $Path 'new settings rollback target'
        if ([System.IO.File]::Exists($FailedTemporaryPath)) {
            throw "new settings rollback recovery path already exists: $FailedTemporaryPath"
        }
        [System.IO.File]::Move($Path, $FailedTemporaryPath)
        Assert-NoReparsePath $FailedTemporaryPath 'new settings rollback recovery'
        if (-not (Test-ByteArraysEqual (
            Read-BoundedSharedFileBytes (
                $FailedTemporaryPath
            ) $script:MaxSettingsBytes 'new settings rollback recovery'
        ) $Plan.UpdatedBytes)) {
            throw "new settings changed concurrently during rollback; recovery copy retained at $FailedTemporaryPath"
        }
    }
}

function Commit-Settings(
    [string]$Path,
    $Plan,
    [string]$BackupPath,
    [string]$TemporaryPath,
    [string]$RestoreTemporaryPath
) {
    $backupComplete = $false
    $targetMutated = $false
    $concurrentConflict = $false
    $concurrentRestored = $false
    try {
        Assert-SafeExistingFile $Path 'settings path'
        Write-BytesCreateNew $TemporaryPath $Plan.UpdatedBytes
        Assert-NoReparsePath $TemporaryPath 'settings temporary file'
        if ($Plan.Existed) {
            if (-not (Test-ByteArraysEqual (
                Read-BoundedSharedFileBytes (
                    $Path
                ) $script:MaxSettingsBytes 'settings pre-commit target'
            ) $Plan.OriginalBytes)) {
                throw 'settings changed before commit'
            }
            [System.IO.File]::Replace($TemporaryPath, $Path, $BackupPath)
            $targetMutated = $true
            $backupComplete = $true
            Assert-NoReparsePath $BackupPath 'displaced settings backup'
            $displaced = Read-BoundedSharedFileBytes (
                $BackupPath
            ) $script:MaxSettingsBytes 'displaced settings backup'
            if (-not (Test-ByteArraysEqual $displaced $Plan.OriginalBytes)) {
                $concurrentConflict = $true
                Assert-NoReparsePath $Path 'concurrent settings restore target'
                if (-not [System.IO.File]::Exists($Path) -or
                    -not (Test-ByteArraysEqual (
                        Read-BoundedSharedFileBytes (
                            $Path
                        ) $script:MaxSettingsBytes 'concurrent settings restore target'
                    ) $Plan.UpdatedBytes)) {
                    throw "settings changed again after replacement; displaced bytes retained at $BackupPath"
                }
                if ([System.IO.File]::Exists($RestoreTemporaryPath)) {
                    throw "settings recovery path already exists: $RestoreTemporaryPath"
                }
                [System.IO.File]::Replace($BackupPath, $Path, $RestoreTemporaryPath)
                $backupComplete = $false
                Assert-NoReparsePath $RestoreTemporaryPath 'displaced installer settings'
                if (-not (Test-ByteArraysEqual (
                    Read-BoundedSharedFileBytes (
                        $RestoreTemporaryPath
                    ) $script:MaxSettingsBytes 'displaced installer settings'
                ) $Plan.UpdatedBytes)) {
                    throw "settings changed again during concurrent restoration; recovery copy retained at $RestoreTemporaryPath"
                }
                if (-not (Test-ByteArraysEqual (
                    Read-BoundedSharedFileBytes (
                        $Path
                    ) $script:MaxSettingsBytes 'concurrent restored settings'
                ) $displaced)) {
                    throw 'concurrent settings restoration verification failed'
                }
                $concurrentRestored = $true
                $targetMutated = $false
                throw 'settings changed concurrently at commit'
            }
        } else {
            [System.IO.File]::Move($TemporaryPath, $Path)
            $targetMutated = $true
        }
        Assert-NoReparsePath $Path 'committed settings'
        if (-not (Test-ByteArraysEqual (
            Read-BoundedSharedFileBytes (
                $Path
            ) $script:MaxSettingsBytes 'committed settings'
        ) $Plan.UpdatedBytes)) {
            $concurrentConflict = $true
            throw 'settings changed after commit; current bytes preserved'
        }
        return $backupComplete
    } catch {
        $failure = $_.Exception.Message
        if ($targetMutated -and -not $concurrentConflict) {
            try {
                Restore-SettingsOriginal $Path $Plan $BackupPath $RestoreTemporaryPath
                $backupComplete = $false
            } catch {
                throw "settings commit failed ($failure); settings rollback also failed: $($_.Exception.Message)"
            }
        }
        if ($concurrentConflict) {
            if ($concurrentRestored) {
                throw "settings commit failed; concurrent settings restored; displaced installer bytes retained at ${RestoreTemporaryPath}: $failure"
            }
            throw "settings commit failed after concurrent change; recovery artifacts retained: $failure"
        }
        if ($targetMutated) {
            throw "settings commit failed; original settings restored; displaced bytes retained at ${RestoreTemporaryPath}: $failure"
        }
        throw "settings commit failed before target mutation: $failure"
    } finally {
        if ([System.IO.File]::Exists($TemporaryPath)) {
            Assert-NoReparsePath $TemporaryPath 'settings temporary cleanup'
            if (Test-ByteArraysEqual (
                [System.IO.File]::ReadAllBytes($TemporaryPath)
            ) $Plan.UpdatedBytes) {
                Remove-SafeInstallerFile $TemporaryPath $TemporaryPath 'settings temporary file'
            }
        }
    }
}

function Test-DirectoryEmpty([string]$Path) {
    return [System.IO.Directory]::GetFileSystemEntries($Path).Length -eq 0
}

function Remove-EmptyCreatedRuntime([string]$Destination, [bool]$DestinationExisted) {
    if ($DestinationExisted) { return }
    $themes = [System.IO.Path]::Combine($Destination, 'themes')
    if ([System.IO.Directory]::Exists($themes) -and (Test-DirectoryEmpty $themes)) {
        [System.IO.Directory]::Delete($themes)
    }
    if ([System.IO.Directory]::Exists($Destination) -and (Test-DirectoryEmpty $Destination)) {
        [System.IO.Directory]::Delete($Destination)
    }
}

function Restore-ManagedRuntime(
    [string]$Destination,
    [string]$BackupPath,
    [string[]]$ChangedFiles,
    [bool]$DestinationExisted,
    $Expected
) {
    $hadBackup = @{}
    foreach ($relative in $ChangedFiles) {
        $target = [System.IO.Path]::Combine($Destination, $relative)
        $backup = [System.IO.Path]::Combine($BackupPath, $relative)
        $recovery = "$backup.rollback"
        $hadBackup[$relative] = [System.IO.File]::Exists($backup)
        if ([System.IO.File]::Exists($recovery)) {
            throw "runtime rollback recovery path already exists: $recovery"
        }
        if (-not [System.IO.File]::Exists($target)) {
            if ([bool]$hadBackup[$relative]) {
                throw "runtime rollback target disappeared; backup retained at ${backup}: $relative"
            }
            continue
        }
        Assert-SafeExistingFile $target "runtime rollback target $relative"
        $maximum = $script:MaxThemeBytes
        if ($relative -ceq 'statusline.ps1') { $maximum = $script:MaxRuntimeBytes }
        $current = Read-BoundedSharedFileBytes (
            $target
        ) $maximum "runtime rollback target $relative"
        if (-not (Test-ByteArraysEqual $current $Expected[$relative])) {
            throw "runtime rollback refused to overwrite concurrent bytes at $target"
        }
    }
    if ($ChangedFiles.Count -gt 1) {
        throw "multi-file runtime rollback requires manual recovery; files and backups retained at $BackupPath"
    }

    for ($i = $ChangedFiles.Count - 1; $i -ge 0; $i--) {
        $relative = $ChangedFiles[$i]
        $target = [System.IO.Path]::Combine($Destination, $relative)
        $backup = [System.IO.Path]::Combine($BackupPath, $relative)
        $recovery = "$backup.rollback"
        Assert-SafeExistingFile $target "runtime rollback target $relative"
        Ensure-SafeDirectory ([System.IO.Path]::GetDirectoryName($target)) 'runtime rollback target parent'
        if ([System.IO.File]::Exists($recovery)) {
            throw "runtime rollback recovery path already exists: $recovery"
        }
        if ([bool]$hadBackup[$relative]) {
            if (-not [System.IO.File]::Exists($backup)) {
                throw "runtime rollback backup disappeared: $backup"
            }
            $maximum = $script:MaxThemeBytes
            if ($relative -ceq 'statusline.ps1') { $maximum = $script:MaxRuntimeBytes }
            $original = Read-BoundedSharedFileBytes (
                $backup
            ) $maximum "runtime rollback backup $relative"
            Ensure-SafeDirectory ([System.IO.Path]::GetDirectoryName($recovery)) 'runtime rollback recovery parent'
            [System.IO.File]::Move($target, $recovery)
            Assert-NoReparsePath $recovery "runtime rollback recovery $relative"
            $displaced = Read-BoundedSharedFileBytes (
                $recovery
            ) $maximum "runtime rollback recovery $relative"
            if (-not (Test-ByteArraysEqual $displaced $Expected[$relative])) {
                if (-not [System.IO.File]::Exists($target)) {
                    [System.IO.File]::Move($recovery, $target)
                }
                throw "runtime changed during rollback; concurrent bytes retained at $target or $recovery"
            }
            [System.IO.File]::Move($backup, $target)
            if (-not (Test-ByteArraysEqual (
                Read-BoundedSharedFileBytes (
                    $target
                ) $maximum "restored runtime $relative"
            ) $original)) {
                throw "runtime rollback verification failed: $relative"
            }
        } elseif ([System.IO.File]::Exists($target)) {
            if ([System.IO.File]::Exists($backup)) {
                throw "unexpected runtime rollback backup appeared: $backup"
            }
            Ensure-SafeDirectory ([System.IO.Path]::GetDirectoryName($recovery)) 'runtime rollback recovery parent'
            [System.IO.File]::Move($target, $recovery)
            Assert-NoReparsePath $recovery "new runtime rollback recovery $relative"
            $maximum = $script:MaxThemeBytes
            if ($relative -ceq 'statusline.ps1') { $maximum = $script:MaxRuntimeBytes }
            $displaced = Read-BoundedSharedFileBytes (
                $recovery
            ) $maximum "new runtime rollback recovery $relative"
            if (-not (Test-ByteArraysEqual $displaced $Expected[$relative])) {
                if (-not [System.IO.File]::Exists($target)) {
                    [System.IO.File]::Move($recovery, $target)
                }
                throw "new runtime changed during rollback; concurrent bytes retained at $target or $recovery"
            }
        }
    }
    Remove-EmptyCreatedRuntime $Destination $DestinationExisted
}

function Install-Runtime(
    [string]$StageRoot,
    [string]$Destination,
    [string]$BackupPath,
    $Expected
) {
    $destinationExisted = [System.IO.Directory]::Exists($Destination)
    $changed = New-Object 'System.Collections.Generic.List[string]'
    try {
        if ([System.IO.Directory]::Exists($BackupPath) -or [System.IO.File]::Exists($BackupPath)) {
            throw "runtime backup path already exists: $BackupPath"
        }
        Ensure-SafeDirectory $Destination 'install root'
        foreach ($relative in $script:ManagedFiles) {
            $staged = [System.IO.Path]::Combine($StageRoot, $relative)
            $target = [System.IO.Path]::Combine($Destination, $relative)
            $backup = [System.IO.Path]::Combine($BackupPath, $relative)
            Assert-NoReparsePath $staged "staged $relative"
            Assert-SafeExistingFile $target "installed $relative"
            Ensure-SafeDirectory ([System.IO.Path]::GetDirectoryName($target)) 'managed runtime parent'
            if ([System.IO.File]::Exists($target) -and (Test-FilesEqual $staged $target)) {
                continue
            }

            $expectedBytes = $Expected[$relative]
            if ([System.IO.File]::Exists($target)) {
                Ensure-SafeDirectory ([System.IO.Path]::GetDirectoryName($backup)) 'runtime backup parent'
                Assert-NoReparsePath $backup "runtime backup $relative"
                [System.IO.File]::Replace($staged, $target, $backup)
            } else {
                [System.IO.File]::Move($staged, $target)
            }
            $changed.Add($relative)
            if (-not (Test-ByteArraysEqual ([System.IO.File]::ReadAllBytes($target)) $expectedBytes)) {
                throw "runtime commit verification failed: $relative"
            }
        }
        Assert-ManagedPayloadBytes $Destination $Expected 'installed payload'
        return ,([pscustomobject]@{
            DestinationExisted = $destinationExisted
            ChangedFiles = [string[]]$changed.ToArray()
            BackupCreated = [System.IO.Directory]::Exists($BackupPath)
            Expected = $Expected
        })
    } catch {
        $failure = $_.Exception.Message
        try {
            Restore-ManagedRuntime (
                $Destination
            ) $BackupPath ([string[]]$changed.ToArray()) $destinationExisted $Expected
        } catch {
            throw "runtime install failed ($failure); runtime rollback also failed: $($_.Exception.Message)"
        }
        throw "runtime install failed; previous managed runtime restored: $failure"
    }
}

function Undo-RuntimeInstall(
    [string]$Destination,
    [string]$BackupPath,
    $Transaction
) {
    Restore-ManagedRuntime (
        $Destination
    ) $BackupPath ([string[]]$Transaction.ChangedFiles) (
        [bool]$Transaction.DestinationExisted
    ) $Transaction.Expected
}

function Invoke-CorallineInstall {
    $localMode = $script:LocalMode
    if ($localMode) {
        $sourceRoot = Resolve-CanonicalLocalPath $SourceDirectory 'SourceDirectory'
        $install = Resolve-CanonicalLocalPath $InstallRoot 'InstallRoot'
        $settings = Resolve-CanonicalLocalPath $SettingsPath 'SettingsPath'
    } else {
        Assert-ValidRepoAndRef $Repo $Ref
        $homePath = [string]$HOME
        if ([string]::IsNullOrWhiteSpace($homePath)) {
            $homePath = [System.Environment]::GetFolderPath('UserProfile')
        }
        $homePath = Resolve-CanonicalLocalPath $homePath 'HOME'
        $claudeRoot = [System.IO.Path]::Combine($homePath, '.claude')
        $sourceRoot = $null
        $install = Resolve-CanonicalLocalPath ([System.IO.Path]::Combine($claudeRoot, 'coralline')) 'install root'
        $settings = Resolve-CanonicalLocalPath ([System.IO.Path]::Combine($claudeRoot, 'settings.json')) 'settings path'
    }

    $installParent = Resolve-CanonicalLocalPath ([System.IO.Path]::GetDirectoryName($install)) 'install parent'
    $settingsParent = Resolve-CanonicalLocalPath ([System.IO.Path]::GetDirectoryName($settings)) 'settings parent'
    $config = Resolve-CanonicalLocalPath ([System.IO.Path]::Combine($installParent, 'coralline.conf')) 'config path'
    $powershell = Resolve-CanonicalLocalPath ([System.IO.Path]::Combine($PSHOME, 'powershell.exe')) 'PowerShell executable'
    if (-not [System.IO.File]::Exists($powershell)) { throw "trusted PowerShell executable is missing: $powershell" }
    Assert-CommandPath $powershell 'PowerShell executable'
    Assert-SafeExistingDirectory $install 'install root'
    Assert-SafeExistingFile $settings 'settings path'
    Assert-SafeExistingFile $config 'config path'
    if ($null -ne $sourceRoot) {
        Assert-SafeExistingDirectory $sourceRoot 'source directory'
        if (-not [System.IO.Directory]::Exists($sourceRoot)) { throw "SourceDirectory does not exist: $sourceRoot" }
    }

    $identifier = [guid]::NewGuid().ToString('N')
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff', $script:Invariant)
    $installLeaf = [System.IO.Path]::GetFileName($install)
    $settingsLeaf = [System.IO.Path]::GetFileName($settings)
    $stage = Resolve-CanonicalLocalPath (
        [System.IO.Path]::Combine($installParent, ".$installLeaf.install.$identifier")
    ) 'staging path'
    $runtimeBackup = Resolve-CanonicalLocalPath (
        [System.IO.Path]::Combine($installParent, "$installLeaf.bak.$timestamp.$identifier")
    ) 'runtime backup path'
    $settingsBackup = Resolve-CanonicalLocalPath "$settings.bak.$timestamp.$identifier" 'settings backup path'
    $settingsTemporary = Resolve-CanonicalLocalPath (
        [System.IO.Path]::Combine($settingsParent, ".$settingsLeaf.tmp.$identifier")
    ) 'settings temporary path'
    $settingsRestoreTemporary = Resolve-CanonicalLocalPath (
        [System.IO.Path]::Combine($settingsParent, ".$settingsLeaf.restore.$identifier")
    ) 'settings rollback temporary path'

    $pathEntries = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $sourceRoot) {
        $pathEntries.Add([pscustomobject]@{ Label = 'source directory'; Path = $sourceRoot })
    }
    foreach ($entry in @(
        [pscustomobject]@{ Label = 'install root'; Path = $install },
        [pscustomobject]@{ Label = 'settings path'; Path = $settings },
        [pscustomobject]@{ Label = 'config path'; Path = $config },
        [pscustomobject]@{ Label = 'staging path'; Path = $stage },
        [pscustomobject]@{ Label = 'runtime backup path'; Path = $runtimeBackup },
        [pscustomobject]@{ Label = 'settings backup path'; Path = $settingsBackup },
        [pscustomobject]@{ Label = 'settings temporary path'; Path = $settingsTemporary },
        [pscustomobject]@{ Label = 'settings rollback temporary path'; Path = $settingsRestoreTemporary }
    )) {
        $pathEntries.Add($entry)
    }
    Assert-DisjointPaths $pathEntries.ToArray()
    foreach ($entry in $pathEntries) { Assert-NoReparsePath $entry.Path $entry.Label }

    $runtimePath = Resolve-CanonicalLocalPath (
        [System.IO.Path]::Combine($install, 'statusline.ps1')
    ) 'installed runtime path'
    Assert-CommandPath $runtimePath 'installed runtime path'
    $command = '"' + $powershell + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $runtimePath + '"'
    $desiredStatusLine = '{"type":"command","command":' + (ConvertTo-JsonString $command) + ',"refreshInterval":1}'

    $installMutex = New-Object System.Threading.Mutex(
        $false,
        'Global\coralline-installer'
    )
    $mutexHeld = $false
    $stageExists = $false
    $runtimeChanged = $false
    $settingsChanged = $false
    $runtimeInstalled = $false
    $runtimeTransaction = $null
    $settingsBackupMade = $false
    $resolvedCommit = $null
    try {
        try {
            $mutexHeld = $installMutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $mutexHeld = $true
        }
        if (-not $mutexHeld) {
            throw 'another coralline installer is already targeting these paths'
        }

        Ensure-SafeDirectory $installParent 'install parent'
        if ([System.IO.Directory]::Exists($stage) -or [System.IO.File]::Exists($stage)) {
            throw "staging path already exists: $stage"
        }
        [void][System.IO.Directory]::CreateDirectory($stage)
        Assert-NoReparsePath $stage 'staging path'
        $stageExists = $true

        if ($localMode) {
            Stage-LocalPayload $sourceRoot $stage
        } else {
            $resolvedCommit = Stage-RemotePayload $Repo $Ref $stage
        }
        Assert-ValidStagedPayload $stage
        $runtimeExpected = Get-ManagedPayloadBytes $stage
        $runtimeChanged = -not (Test-ManagedPayloadEqual $stage $install)
        $settingsPlan = Get-SettingsPlan $settings $desiredStatusLine
        $settingsChanged = [bool]$settingsPlan.Changed

        if (-not $runtimeChanged -and -not $settingsChanged) {
            Assert-ManagedPayloadBytes $install $runtimeExpected 'installed payload'
            Assert-SettingsBytes $settings $settingsPlan.UpdatedBytes 'settings before no-op'
            Remove-SafeInstallerDirectory $stage $stage 'staging path'
            $stageExists = $false
            [Console]::Out.WriteLine('coralline is already up to date.')
            return
        }

        if ($runtimeChanged) {
            $runtimeTransaction = Install-Runtime (
                $stage
            ) $install $runtimeBackup $runtimeExpected
            $runtimeInstalled = $true
        }

        if ($settingsChanged) {
            Ensure-SafeDirectory $settingsParent 'settings parent'
            try {
                $settingsBackupMade = Commit-Settings (
                    $settings
                ) $settingsPlan $settingsBackup $settingsTemporary $settingsRestoreTemporary
            } catch {
                $settingsFailure = $_.Exception.Message
                if ($runtimeInstalled) {
                    try {
                        Undo-RuntimeInstall $install $runtimeBackup $runtimeTransaction
                        $runtimeInstalled = $false
                    } catch {
                        throw "settings update failed ($settingsFailure); runtime rollback also failed: $($_.Exception.Message)"
                    }
                    throw "settings update failed; previous managed runtime restored; displaced runtime files retained at ${runtimeBackup}: $settingsFailure"
                }
                throw $settingsFailure
            }
        }

        Assert-ManagedPayloadBytes $install $runtimeExpected 'installed payload before success'
        Assert-SettingsBytes $settings $settingsPlan.UpdatedBytes 'settings before success'
        [Console]::Out.WriteLine("coralline installed at $install")
        if ($null -ne $resolvedCommit) {
            [Console]::Out.WriteLine("resolved $Repo@$Ref to $resolvedCommit")
        }
        if ($runtimeChanged -and [bool]$runtimeTransaction.BackupCreated) {
            [Console]::Out.WriteLine("runtime backup retained at $runtimeBackup")
        }
        if ($settingsChanged -and $settingsBackupMade) {
            [Console]::Out.WriteLine("settings backup retained at $settingsBackup")
        }
        if ([System.IO.File]::Exists($config)) {
            [Console]::Out.WriteLine("config preserved at $config")
        }
    } finally {
        try {
            if ($stageExists -and [System.IO.Directory]::Exists($stage)) {
                Remove-SafeInstallerDirectory $stage $stage 'staging path'
            }
        } finally {
            if ($mutexHeld) {
                $installMutex.ReleaseMutex()
            }
            $installMutex.Dispose()
        }
    }
}

try {
    Invoke-CorallineInstall
    exit 0
} catch {
    [Console]::Error.WriteLine("error: $($_.Exception.Message)")
    exit 1
}
