#Requires -Version 5.1
<#
  Hermetic native installer regression tests.

  Run with Windows PowerShell 5.1:
    powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
      -File test\test-install-ps1.ps1
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Here = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Repo = Split-Path -Path $Here -Parent
$Installer = Join-Path $Repo 'install.ps1'
$PowerShellExe = (Get-Process -Id $PID).Path
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('coralline install 測試 & (ps51)-' + [guid]::NewGuid().ToString('N'))
$script:Pass = 0
$script:Fail = 0
$script:Blocked = 0

$ExpectedThemes = @(
    'catppuccin-mocha.conf',
    'claude-coral.conf',
    'dracula.conf',
    'gruvbox-dark.conf',
    'lunar-pink.conf',
    'mono.conf',
    'morning-haze.conf',
    'nord.conf',
    'reverie.conf',
    'tokyo-night.conf'
)
$ExpectedManaged = @('statusline.ps1') + @($ExpectedThemes | ForEach-Object { 'themes\' + $_ })

function Check([string]$Name, [bool]$Condition) {
    if ($Condition) {
        [Console]::Out.WriteLine("PASS  $Name")
        $script:Pass++
    } else {
        [Console]::Out.WriteLine("FAIL  $Name")
        $script:Fail++
    }
}

function Blocked([string]$Name, [string]$Reason) {
    [Console]::Out.WriteLine("BLOCKED  ${Name}: $Reason")
    $script:Blocked++
}

function Write-Utf8([string]$Path, [string]$Text) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Write-Utf8Bom([string]$Path, [string]$Text) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    $content = $Utf8NoBom.GetBytes($Text)
    $bytes = New-Object byte[] ($content.Length + 3)
    $bytes[0] = 0xef
    $bytes[1] = 0xbb
    $bytes[2] = 0xbf
    [Array]::Copy($content, 0, $bytes, 3, $content.Length)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value.IndexOf('"') -ge 0) { throw 'test process arguments may not contain quotes' }
    return '"' + $Value + '"'
}

function Invoke-CapturedProcess(
    [string]$FileName,
    [string]$Arguments,
    [string]$InputText,
    [hashtable]$Environment,
    [string]$WorkingDirectory,
    [int]$TimeoutMs
) {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $FileName
    $start.Arguments = $Arguments
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $start.WorkingDirectory = $WorkingDirectory }
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) { [void]$start.EnvironmentVariables.Remove($key) }
        else { $start.EnvironmentVariables[$key] = [string]$Environment[$key] }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'process did not start' }
        $stdout = New-Object System.IO.MemoryStream
        $stderr = New-Object System.IO.MemoryStream
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $inputBytes = $Utf8NoBom.GetBytes($InputText)
        if ($inputBytes.Length -gt 0) {
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
        }
        $process.StandardInput.Close()
        $timedOut = -not $process.WaitForExit($TimeoutMs)
        if ($timedOut) {
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(2000)
        }
        [void]$outTask.Wait(2000)
        [void]$errTask.Wait(2000)
        $outBytes = $stdout.ToArray()
        $errBytes = $stderr.ToArray()
        try { $outText = $StrictUtf8.GetString($outBytes) } catch { $outText = $null }
        try { $errText = $StrictUtf8.GetString($errBytes) } catch { $errText = $null }
        $exitCode = -1
        if (-not $timedOut -and $process.HasExited) { $exitCode = $process.ExitCode }
        $stdout.Dispose()
        $stderr.Dispose()
        return [pscustomobject]@{
            ExitCode = $exitCode
            TimedOut = $timedOut
            Stdout = $outText
            Stderr = $errText
            StdoutBytes = $outBytes
            StderrBytes = $errBytes
        }
    } catch {
        return [pscustomobject]@{
            ExitCode = -1
            TimedOut = $false
            Stdout = ''
            Stderr = $_.Exception.Message
            StdoutBytes = [byte[]]@()
            StderrBytes = $Utf8NoBom.GetBytes($_.Exception.Message)
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-Installer([string]$Source, [string]$Install, [string]$Settings) {
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy Bypass',
        '-File ' + (Quote-ProcessArgument $Installer),
        '-SourceDirectory ' + (Quote-ProcessArgument $Source),
        '-InstallRoot ' + (Quote-ProcessArgument $Install),
        '-SettingsPath ' + (Quote-ProcessArgument $Settings)
    ) -join ' '
    $environment = @{
        CORALLINE_REPO = 'must-not-be-read'
        CORALLINE_REF = 'must-not-be-read'
        CORALLINE_BASE_URL = 'https://127.0.0.1:1/must-not-be-read'
    }
    return Invoke-CapturedProcess $PowerShellExe $arguments '' $environment $Repo 30000
}

function New-Paths([string]$Name) {
    $fixtureHome = Join-Path $TempRoot $Name
    $claude = Join-Path $fixtureHome '.claude'
    return [pscustomobject]@{
        Home = $fixtureHome
        Claude = $claude
        Install = (Join-Path $claude 'coralline')
        Settings = (Join-Path $claude 'settings.json')
        Config = (Join-Path $claude 'coralline.conf')
    }
}

function ConvertTo-TestJsonString([string]$Value) {
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

function Get-DesiredCommand([string]$Install) {
    $exe = [IO.Path]::GetFullPath((Join-Path $PSHOME 'powershell.exe'))
    $runtime = [IO.Path]::GetFullPath((Join-Path $Install 'statusline.ps1'))
    return '"' + $exe + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $runtime + '"'
}

function Get-DesiredValue([string]$Install) {
    return '{"type":"command","command":' +
        (ConvertTo-TestJsonString (Get-DesiredCommand $Install)) +
        ',"refreshInterval":1}'
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-ManagedSnapshot([string]$Install, [string]$Settings) {
    $snapshot = [ordered]@{}
    foreach ($relative in $ExpectedManaged) {
        $path = Join-Path $Install $relative
        $item = Get-Item -LiteralPath $path
        $snapshot["file:$relative"] = (Get-FileSha256 $path) + ':' + $item.LastWriteTimeUtc.Ticks
    }
    $installItem = Get-Item -LiteralPath $Install
    $settingsItem = Get-Item -LiteralPath $Settings
    $snapshot['install-times'] = "$($installItem.CreationTimeUtc.Ticks):$($installItem.LastWriteTimeUtc.Ticks)"
    $snapshot['settings'] = (Get-FileSha256 $Settings) + ':' + $settingsItem.LastWriteTimeUtc.Ticks
    return ,$snapshot
}

function Test-SnapshotsEqual($First, $Second) {
    if ($First.Count -ne $Second.Count) { return $false }
    foreach ($key in $First.Keys) {
        if (-not $Second.Contains($key) -or $First[$key] -cne $Second[$key]) { return $false }
    }
    return $true
}

function Get-RelativeFileSnapshot(
    [string]$Root,
    [string[]]$RelativePaths,
    [bool]$IncludeTimestamps
) {
    $snapshot = [ordered]@{}
    foreach ($relative in $RelativePaths) {
        $path = Join-Path $Root $relative
        $value = Get-FileSha256 $path
        if ($IncludeTimestamps) {
            $value += ':' + (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
        }
        $snapshot[$relative] = $value
    }
    return ,$snapshot
}

function Get-BackupCount([string]$Directory, [string]$Pattern) {
    if (-not [IO.Directory]::Exists($Directory)) { return 0 }
    return @([IO.Directory]::GetFileSystemEntries($Directory, $Pattern)).Count
}

function Test-InvalidSettings([string]$Name, [string]$Text) {
    $paths = New-Paths ('invalid-' + $Name)
    [void][IO.Directory]::CreateDirectory($paths.Claude)
    Write-Utf8 $paths.Settings $Text
    $before = [IO.File]::ReadAllBytes($paths.Settings)
    $run = Invoke-Installer $Repo $paths.Install $paths.Settings
    Check "$Name rejected" (-not $run.TimedOut -and $run.ExitCode -ne 0)
    Check "$Name settings unchanged" (
        [Convert]::ToBase64String($before) -ceq
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($paths.Settings))
    )
    Check "$Name runtime not installed" (-not [IO.Directory]::Exists($paths.Install))
    Check "$Name no settings backup" ((Get-BackupCount $paths.Claude 'settings.json.bak.*') -eq 0)
}

function Copy-ManagedSource([string]$Destination) {
    foreach ($relative in $ExpectedManaged) {
        $source = Join-Path $Repo $relative
        $target = Join-Path $Destination $relative
        $parent = [IO.Path]::GetDirectoryName($target)
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
        [IO.File]::Copy($source, $target, $false)
    }
}

function Get-InstallerCommitFunctions {
    $wanted = @(
        'Test-HasControlCharacter',
        'Assert-SafePathSegments',
        'Resolve-CanonicalLocalPath',
        'Assert-NoReparsePath',
        'Assert-SafeExistingFile',
        'Remove-SafeInstallerFile',
        'Test-ByteArraysEqual',
        'Read-BoundedSharedFileBytes',
        'Write-BytesCreateNew',
        'Restore-SettingsOriginal',
        'Commit-Settings'
    )
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $Installer,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -ne 0) { throw 'cannot parse installer functions for regression test' }
    $functions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $wanted -contains $_.Name })
    if ($functions.Count -ne $wanted.Count) { throw 'installer commit function set is incomplete' }
    return ($functions | ForEach-Object { $_.Extent.Text }) -join "`r`n"
}

if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSEdition -ne 'Desktop') {
    [Console]::Error.WriteLine('error: run this suite on native Windows PowerShell 5.1 Desktop')
    exit 1
}

[void][IO.Directory]::CreateDirectory($TempRoot)
try {
    $repoThemes = @(
        Get-ChildItem -LiteralPath (Join-Path $Repo 'themes') -File -Filter '*.conf' |
            Select-Object -ExpandProperty Name |
            Sort-Object
    )
    Check 'allowlist has exactly ten themes' ($ExpectedThemes.Count -eq 10)
    Check 'allowlist equals shipped themes' (
        (($ExpectedThemes | Sort-Object) -join "`n") -ceq ($repoThemes -join "`n")
    )

    $main = New-Paths 'home Ω & (accepted)'
    [void][IO.Directory]::CreateDirectory($main.Claude)
    $configText = '# preserved config' + "`n" + 'VL_STYLE="lean"' + "`n" + '# 雪' + "`n"
    Write-Utf8 $main.Config $configText
    $configHash = Get-FileSha256 $main.Config

    $prefix = '{' + "`r`n" +
        '  "deep": {"非ASCII":"雪","items":[1,{"x":[true,false,null]}]},' + "`r`n" +
        '  "maximum": 9223372036854775807,' + "`r`n" +
        '  "minimum": -9223372036854775808,' + "`r`n" +
        '  "precise": 123456789012345678901234567890.0000000000000000001e+999,' + "`r`n" +
        '  "StatusLine": {"keep":true},' + "`r`n" +
        '  "statusline": "lower-case stays",' + "`r`n" +
        '  "statusLine": '
    $oldManaged = '{ "old": true, "refreshInterval": 99 }'
    $suffix = ',' + "`r`n" + '  "tail": "unchanged\\value"' + "`r`n" + '}' + "`r`n"
    Write-Utf8 $main.Settings ($prefix + $oldManaged + $suffix)

    $fresh = Invoke-Installer $Repo $main.Install $main.Settings
    Check 'fresh install no timeout' (-not $fresh.TimedOut)
    Check 'fresh install exit 0' ($fresh.ExitCode -eq 0)
    Check 'fresh install no stderr' ($fresh.StderrBytes.Length -eq 0)
    if ($fresh.ExitCode -ne 0) {
        [Console]::Out.WriteLine('DIAG  fresh stderr=' + [Convert]::ToBase64String($fresh.StderrBytes))
    }

    $installedFiles = @(
        Get-ChildItem -LiteralPath $main.Install -File -Recurse |
            ForEach-Object { $_.FullName.Substring($main.Install.Length + 1).Replace('/', '\') } |
            Sort-Object
    )
    Check 'installed exact 11-file inventory' (
        (($ExpectedManaged | Sort-Object) -join "`n") -ceq ($installedFiles -join "`n")
    )
    Check 'installed exact ten-theme inventory' (
        @(Get-ChildItem -LiteralPath (Join-Path $main.Install 'themes') -File).Count -eq 10
    )

    $desiredCommand = Get-DesiredCommand $main.Install
    $desiredValue = Get-DesiredValue $main.Install
    $settingsText = $StrictUtf8.GetString([IO.File]::ReadAllBytes($main.Settings))
    Check 'lossless raw settings merge' ($settingsText -ceq ($prefix + $desiredValue + $suffix))
    Check 'numeric lexemes preserved' (
        $settingsText.Contains('9223372036854775807') -and
        $settingsText.Contains('-9223372036854775808') -and
        $settingsText.Contains('123456789012345678901234567890.0000000000000000001e+999')
    )
    Check 'case-distinct and non-ASCII members preserved' (
        $settingsText.Contains('"StatusLine": {"keep":true}') -and
        $settingsText.Contains('"statusline": "lower-case stays"') -and
        $settingsText.Contains('"非ASCII":"雪"')
    )
    $managedObject = $desiredValue | ConvertFrom-Json
    Check 'settings type command' ($managedObject.type -ceq 'command')
    Check 'settings command exact absolute trusted executable' ($managedObject.command -ceq $desiredCommand)
    Check 'settings command contains Bypass' ($managedObject.command.Contains('-ExecutionPolicy Bypass'))
    Check 'settings refreshInterval 1' ($managedObject.refreshInterval -eq 1)
    Check 'config hash preserved' ((Get-FileSha256 $main.Config) -ceq $configHash)

    $preservedFiles = @(
        'burn-5h.tsv',
        'burn-5h.d\1710000000.010.000.host.1.0001',
        'limit-5h.d\1710000000.020.000.host.1.0001',
        'limit-7d.d\1710000000.030.000.host.1.0001',
        'float.txt',
        'themes\custom-local.conf',
        'custom-state\nested\keep.txt'
    )
    foreach ($relative in $preservedFiles) {
        Write-Utf8 (Join-Path $main.Install $relative) ("preserve:$relative`n")
    }
    $preservedTimedBefore = Get-RelativeFileSnapshot $main.Install $preservedFiles $true

    $snapshotBefore = Get-ManagedSnapshot $main.Install $main.Settings
    $runtimeBackupsBefore = Get-BackupCount $main.Claude 'coralline.bak.*'
    $settingsBackupsBefore = Get-BackupCount $main.Claude 'settings.json.bak.*'
    Start-Sleep -Milliseconds 1200
    $second = Invoke-Installer $Repo $main.Install $main.Settings
    $snapshotAfter = Get-ManagedSnapshot $main.Install $main.Settings
    Check 'identical rerun exit 0' ($second.ExitCode -eq 0)
    Check 'identical rerun reports no-op' ($second.Stdout -ceq "coralline is already up to date.`r`n")
    Check 'identical rerun preserves hashes and timestamps' (Test-SnapshotsEqual $snapshotBefore $snapshotAfter)
    Check 'identical rerun creates no runtime backup' (
        (Get-BackupCount $main.Claude 'coralline.bak.*') -eq $runtimeBackupsBefore
    )
    Check 'identical rerun creates no settings backup' (
        (Get-BackupCount $main.Claude 'settings.json.bak.*') -eq $settingsBackupsBefore
    )
    Check 'identical rerun preserves config' ((Get-FileSha256 $main.Config) -ceq $configHash)
    Check 'identical rerun preserves runtime state and custom files' (
        Test-SnapshotsEqual $preservedTimedBefore (
            Get-RelativeFileSnapshot $main.Install $preservedFiles $true
        )
    )

    $updateSource = Join-Path $TempRoot 'state-update-source'
    Copy-ManagedSource $updateSource
    [IO.File]::AppendAllText(
        (Join-Path $updateSource 'themes\mono.conf'),
        ("`n" + '# state-preserving update' + "`n"),
        $Utf8NoBom
    )
    $preservedSnapshotBeforeUpdate = Get-RelativeFileSnapshot $main.Install $preservedFiles $true
    $stateUpdate = Invoke-Installer $updateSource $main.Install $main.Settings
    Check 'changed runtime update exit 0' ($stateUpdate.ExitCode -eq 0)
    Check 'changed runtime update does not touch runtime state and custom files' (
        Test-SnapshotsEqual $preservedSnapshotBeforeUpdate (
            Get-RelativeFileSnapshot $main.Install $preservedFiles $true
        )
    )

    $oversized = New-Paths 'oversized-unmanaged'
    $oversizedFresh = Invoke-Installer $Repo $oversized.Install $oversized.Settings
    Check 'oversized fixture fresh install' ($oversizedFresh.ExitCode -eq 0)
    $oversizedFile = Join-Path $oversized.Install 'oversized-state.bin'
    [IO.File]::WriteAllBytes($oversizedFile, (New-Object byte[] (2MB + 1)))
    $oversizedHash = Get-FileSha256 $oversizedFile
    $oversizedBackups = Get-BackupCount $oversized.Claude 'coralline.bak.*'
    $oversizedSource = Join-Path $TempRoot 'oversized-source'
    Copy-ManagedSource $oversizedSource
    [IO.File]::AppendAllText(
        (Join-Path $oversizedSource 'themes\mono.conf'),
        ("`n" + '# oversized preservation rejection' + "`n"),
        $Utf8NoBom
    )
    $oversizedRun = Invoke-Installer $oversizedSource $oversized.Install $oversized.Settings
    Check 'oversized unmanaged content does not block update' ($oversizedRun.ExitCode -eq 0)
    Check 'oversized unmanaged update installs changed runtime' (
        (Get-FileSha256 (Join-Path $oversized.Install 'themes\mono.conf')) -ceq
        (Get-FileSha256 (Join-Path $oversizedSource 'themes\mono.conf'))
    )
    Check 'oversized unmanaged update preserves unmanaged bytes' (
        (Get-FileSha256 $oversizedFile) -ceq $oversizedHash
    )
    Check 'oversized unmanaged update creates one runtime backup' (
        (Get-BackupCount $oversized.Claude 'coralline.bak.*') -eq ($oversizedBackups + 1)
    )

    $unmanagedTarget = Join-Path $oversized.Home 'unmanaged-junction-target'
    $unmanagedJunction = Join-Path $oversized.Install 'unmanaged-junction'
    [void][IO.Directory]::CreateDirectory($unmanagedTarget)
    Write-Utf8 (Join-Path $unmanagedTarget 'canary.txt') 'keep'
    $unmanagedJunctionCreate = Invoke-CapturedProcess $env:ComSpec (
        '/d /s /c "mklink /J ' + (Quote-ProcessArgument $unmanagedJunction) + ' ' +
        (Quote-ProcessArgument $unmanagedTarget) + '"'
    ) '' @{} $TempRoot 10000
    if ($unmanagedJunctionCreate.ExitCode -eq 0 -and
        [IO.Directory]::Exists($unmanagedJunction)) {
        $unmanagedJunctionRun = Invoke-Installer (
            $oversizedSource
        ) $oversized.Install $oversized.Settings
        Check 'unmanaged reparse entry does not block no-op' (
            $unmanagedJunctionRun.ExitCode -eq 0 -and
            $unmanagedJunctionRun.Stdout -ceq "coralline is already up to date.`r`n"
        )
        Check 'unmanaged reparse entry remains in place' (
            [IO.Directory]::Exists($unmanagedJunction)
        )
        Check 'unmanaged reparse canary preserved' (
            [IO.File]::ReadAllText(
                (Join-Path $unmanagedTarget 'canary.txt'),
                $StrictUtf8
            ) -ceq 'keep'
        )
        [void](Invoke-CapturedProcess $env:ComSpec (
            '/d /s /c "rmdir ' + (Quote-ProcessArgument $unmanagedJunction) + '"'
        ) '' @{} $TempRoot 10000)
    } else {
        Blocked 'unmanaged reparse no-op' 'mklink /J was unavailable in this Windows environment'
    }

    $noConfig = New-Paths 'no-config'
    $noConfigRun = Invoke-Installer $Repo $noConfig.Install $noConfig.Settings
    Check 'fresh missing-settings install exit 0' ($noConfigRun.ExitCode -eq 0)
    Check 'installer never creates config' (-not [IO.File]::Exists($noConfig.Config))
    Check 'new settings has no backup' ((Get-BackupCount $noConfig.Claude 'settings.json.bak.*') -eq 0)

    $expandedLimit = New-Paths 'expanded-settings-limit'
    $limitPrefix = '{"padding":"'
    $limitSuffix = '"}'
    $paddingLength = 8MB - $Utf8NoBom.GetByteCount($limitPrefix + $limitSuffix)
    $limitBuilder = New-Object System.Text.StringBuilder
    [void]$limitBuilder.Append($limitPrefix)
    [void]$limitBuilder.Append(([char]'x'), [int]$paddingLength)
    [void]$limitBuilder.Append($limitSuffix)
    Write-Utf8 $expandedLimit.Settings $limitBuilder.ToString()
    [void]$limitBuilder.Clear()
    $expandedLimitHash = Get-FileSha256 $expandedLimit.Settings
    $expandedLimitRun = Invoke-Installer $Repo $expandedLimit.Install $expandedLimit.Settings
    Check 'post-merge settings size limit rejected' ($expandedLimitRun.ExitCode -ne 0)
    Check 'post-merge size rejection preserves settings bytes' (
        (Get-FileSha256 $expandedLimit.Settings) -ceq $expandedLimitHash
    )
    Check 'post-merge size rejection happens before runtime mutation' (
        -not [IO.Directory]::Exists($expandedLimit.Install)
    )
    Check 'post-merge size rejection creates no backup' (
        (Get-BackupCount $expandedLimit.Claude 'settings.json.bak.*') -eq 0
    )

    $bom = New-Paths 'bom-settings'
    Write-Utf8Bom $bom.Settings '{"keep":"雪","statusLine":null}'
    $bomRun = Invoke-Installer $Repo $bom.Install $bom.Settings
    $bomBytes = [IO.File]::ReadAllBytes($bom.Settings)
    Check 'UTF-8 BOM settings install exit 0' ($bomRun.ExitCode -eq 0)
    Check 'UTF-8 BOM preserved during merge' (
        $bomBytes.Length -ge 3 -and
        $bomBytes[0] -eq 0xef -and $bomBytes[1] -eq 0xbb -and $bomBytes[2] -eq 0xbf
    )
    Check 'UTF-8 BOM merge preserves unrelated content' (
        $StrictUtf8.GetString($bomBytes, 3, $bomBytes.Length - 3) -ceq
        ('{"keep":"雪","statusLine":' + (Get-DesiredValue $bom.Install) + '}')
    )
    $bomItem = Get-Item -LiteralPath $bom.Settings
    $bomSnapshot = (Get-FileSha256 $bom.Settings) + ':' + $bomItem.LastWriteTimeUtc.Ticks
    $bomBackups = Get-BackupCount $bom.Claude 'settings.json.bak.*'
    Start-Sleep -Milliseconds 1200
    $bomSecond = Invoke-Installer $Repo $bom.Install $bom.Settings
    $bomItemAfter = Get-Item -LiteralPath $bom.Settings
    Check 'UTF-8 BOM identical rerun reports no-op' (
        $bomSecond.ExitCode -eq 0 -and
        $bomSecond.Stdout -ceq "coralline is already up to date.`r`n"
    )
    Check 'UTF-8 BOM identical rerun changes no bytes or timestamp' (
        ((Get-FileSha256 $bom.Settings) + ':' + $bomItemAfter.LastWriteTimeUtc.Ticks) -ceq $bomSnapshot
    )
    Check 'UTF-8 BOM identical rerun creates no backup' (
        (Get-BackupCount $bom.Claude 'settings.json.bak.*') -eq $bomBackups
    )

    Test-InvalidSettings 'malformed' '{"x":'
    Test-InvalidSettings 'null-root' 'null'
    Test-InvalidSettings 'array-root' '[1,2,3]'
    Test-InvalidSettings 'duplicate-exact' '{"statusLine":1,"status\u004cine":2}'

    . ([scriptblock]::Create((Get-InstallerCommitFunctions)))
    $script:MaxSettingsBytes = 8MB
    $lockedPaths = New-Paths 'concurrent-installer-lock'
    $heldMutex = New-Object System.Threading.Mutex(
        $false,
        'Global\coralline-installer'
    )
    $heldMutexAcquired = $false
    try {
        $heldMutexAcquired = $heldMutex.WaitOne(0)
        if (-not $heldMutexAcquired) { throw 'test could not acquire installer mutex' }
        $lockedRun = Invoke-Installer $Repo $lockedPaths.Install $lockedPaths.Settings
    } finally {
        if ($heldMutexAcquired) { $heldMutex.ReleaseMutex() }
        $heldMutex.Dispose()
    }
    Check 'concurrent installer transaction rejected' (
        $lockedRun.ExitCode -ne 0 -and
        $lockedRun.Stderr.Contains('another coralline installer is already targeting')
    )
    Check 'concurrent installer rejection mutates no targets' (
        -not [IO.Directory]::Exists($lockedPaths.Install) -and
        -not [IO.File]::Exists($lockedPaths.Settings) -and
        (Get-BackupCount $lockedPaths.Claude '*.bak.*') -eq 0
    )

    $concurrentRoot = Join-Path $TempRoot 'concurrent-settings'
    [void][IO.Directory]::CreateDirectory($concurrentRoot)
    $concurrentSettings = Join-Path $concurrentRoot 'settings.json'
    $plannedBytes = $Utf8NoBom.GetBytes('{"value":"planned"}')
    $concurrentBytes = $Utf8NoBom.GetBytes('{"value":"concurrent"}')
    [IO.File]::WriteAllBytes($concurrentSettings, $concurrentBytes)
    $concurrentPlan = [pscustomobject]@{
        Existed = $true
        OriginalBytes = $plannedBytes
        UpdatedBytes = $Utf8NoBom.GetBytes('{"value":"installer"}')
        Changed = $true
    }
    $concurrentBackup = Join-Path $concurrentRoot 'settings.json.bak'
    $concurrentTemporary = Join-Path $concurrentRoot '.settings.json.tmp'
    $concurrentRestore = Join-Path $concurrentRoot '.settings.json.restore'
    $concurrentRejected = $false
    try {
        [void](Commit-Settings (
            $concurrentSettings
        ) $concurrentPlan $concurrentBackup $concurrentTemporary $concurrentRestore)
    } catch {
        $concurrentRejected = $_.Exception.Message.Contains('before target mutation')
    }
    Check 'pre-commit concurrent settings change rejected' $concurrentRejected
    Check 'pre-commit concurrent settings bytes preserved' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($concurrentSettings)) -ceq
        [Convert]::ToBase64String($concurrentBytes)
    )
    Check 'pre-commit concurrent failure leaves no artifacts' (
        -not [IO.File]::Exists($concurrentBackup) -and
        -not [IO.File]::Exists($concurrentTemporary) -and
        -not [IO.File]::Exists($concurrentRestore)
    )

    $newRollbackRoot = Join-Path $TempRoot 'new-settings-rollback'
    [void][IO.Directory]::CreateDirectory($newRollbackRoot)
    $newRollbackSettings = Join-Path $newRollbackRoot 'settings.json'
    $newRollbackRecovery = Join-Path $newRollbackRoot '.settings.json.recovery'
    $newRollbackRestore = Join-Path $newRollbackRoot '.settings.json.restore'
    $newRollbackInstaller = $Utf8NoBom.GetBytes('{"value":"installer"}')
    $newRollbackConcurrent = $Utf8NoBom.GetBytes('{"value":"concurrent"}')
    [IO.File]::WriteAllBytes($newRollbackSettings, $newRollbackConcurrent)
    $newRollbackPlan = [pscustomobject]@{
        Existed = $false
        OriginalBytes = [byte[]]@()
        UpdatedBytes = $newRollbackInstaller
        Changed = $true
    }
    $newRollbackReported = $false
    try {
        Restore-SettingsOriginal (
            $newRollbackSettings
        ) $newRollbackPlan $newRollbackRestore $newRollbackRecovery
    } catch {
        $newRollbackReported = (
            $_.Exception.Message.Contains('recovery copy retained at') -and
            $_.Exception.Message.Contains($newRollbackRecovery)
        )
    }
    Check 'new settings rollback reports displaced concurrent recovery' $newRollbackReported
    Check 'new settings rollback never deletes concurrent bytes' (
        -not [IO.File]::Exists($newRollbackSettings) -and
        [IO.File]::Exists($newRollbackRecovery) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($newRollbackRecovery)) -ceq
        [Convert]::ToBase64String($newRollbackConcurrent)
    )

    $existingRecoveryRoot = Join-Path $TempRoot 'existing-settings-recovery'
    [void][IO.Directory]::CreateDirectory($existingRecoveryRoot)
    $existingRecoverySettings = Join-Path $existingRecoveryRoot 'settings.json'
    $existingRecoveryRestore = Join-Path $existingRecoveryRoot '.settings.json.restore'
    $existingRecoveryFailed = Join-Path $existingRecoveryRoot '.settings.json.failed'
    $existingRecoveryOriginal = $Utf8NoBom.GetBytes('{"value":"original"}')
    $existingRecoveryUpdated = $Utf8NoBom.GetBytes('{"value":"installer"}')
    $existingRecoveryExternal = $Utf8NoBom.GetBytes('{"value":"external"}')
    $existingRecoveryPlan = [pscustomobject]@{
        Existed = $true
        OriginalBytes = $existingRecoveryOriginal
        UpdatedBytes = $existingRecoveryUpdated
        Changed = $true
    }
    [IO.File]::WriteAllBytes($existingRecoverySettings, $existingRecoveryUpdated)
    [IO.File]::WriteAllBytes($existingRecoveryRestore, $existingRecoveryExternal)
    $unexpectedRestoreReported = $false
    try {
        Restore-SettingsOriginal (
            $existingRecoverySettings
        ) $existingRecoveryPlan $existingRecoveryRestore $existingRecoveryFailed
    } catch {
        $unexpectedRestoreReported = $_.Exception.Message.Contains(
            $existingRecoveryRestore
        )
    }
    Check 'unexpected rollback source reports exact retained path' $unexpectedRestoreReported
    Check 'unexpected rollback source bytes remain untouched' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($existingRecoverySettings)) -ceq
        [Convert]::ToBase64String($existingRecoveryUpdated) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($existingRecoveryRestore)) -ceq
        [Convert]::ToBase64String($existingRecoveryExternal)
    )

    $failedRecoveryRoot = Join-Path $TempRoot 'failed-settings-recovery'
    [void][IO.Directory]::CreateDirectory($failedRecoveryRoot)
    $failedRecoverySettings = Join-Path $failedRecoveryRoot 'settings.json'
    $failedRecoveryRestore = Join-Path $failedRecoveryRoot '.settings.json.restore'
    $failedRecoveryPath = Join-Path $failedRecoveryRoot '.settings.json.failed'
    [IO.File]::WriteAllBytes($failedRecoverySettings, $existingRecoveryUpdated)
    [IO.File]::WriteAllBytes($failedRecoveryRestore, $existingRecoveryOriginal)
    [IO.File]::WriteAllBytes($failedRecoveryPath, $existingRecoveryExternal)
    $unexpectedFailedReported = $false
    try {
        Restore-SettingsOriginal (
            $failedRecoverySettings
        ) $existingRecoveryPlan $failedRecoveryRestore $failedRecoveryPath
    } catch {
        $unexpectedFailedReported = $_.Exception.Message.Contains($failedRecoveryPath)
    }
    Check 'unexpected rollback destination reports exact retained path' $unexpectedFailedReported
    Check 'unexpected rollback destination bytes remain untouched' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($failedRecoverySettings)) -ceq
        [Convert]::ToBase64String($existingRecoveryUpdated) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($failedRecoveryPath)) -ceq
        [Convert]::ToBase64String($existingRecoveryExternal)
    )

    $openHandleRoot = Join-Path $TempRoot 'open-handle-settings'
    [void][IO.Directory]::CreateDirectory($openHandleRoot)
    $openHandleSettings = Join-Path $openHandleRoot 'settings.json'
    $openHandleBackup = Join-Path $openHandleRoot 'settings.json.bak'
    $openHandleTemporary = Join-Path $openHandleRoot '.settings.json.tmp'
    $openHandleRestore = Join-Path $openHandleRoot '.settings.json.restore'
    $openHandleOriginal = $Utf8NoBom.GetBytes('{"value":"original"}')
    $openHandleUpdated = $Utf8NoBom.GetBytes('{"value":"installer"}')
    $openHandleExternal = $Utf8NoBom.GetBytes('{"value":"external-after-commit"}')
    [IO.File]::WriteAllBytes($openHandleSettings, $openHandleOriginal)
    $openHandlePlan = [pscustomobject]@{
        Existed = $true
        OriginalBytes = $openHandleOriginal
        UpdatedBytes = $openHandleUpdated
        Changed = $true
    }
    $sharedHandle = [IO.File]::Open(
        $openHandleSettings,
        [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    )
    try {
        $openHandleBackupMade = Commit-Settings (
            $openHandleSettings
        ) $openHandlePlan $openHandleBackup $openHandleTemporary $openHandleRestore
        $sharedHandle.Position = 0
        $sharedHandle.SetLength(0)
        $sharedHandle.Write($openHandleExternal, 0, $openHandleExternal.Length)
        $sharedHandle.Flush($true)
    } finally {
        $sharedHandle.Dispose()
    }
    Check 'open settings handle commit retains displaced file as backup' (
        $openHandleBackupMade -and
        [IO.File]::Exists($openHandleBackup)
    )
    Check 'open settings handle post-commit edit survives in retained backup' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($openHandleBackup)) -ceq
        [Convert]::ToBase64String($openHandleExternal)
    )
    Check 'open settings handle leaves committed settings intact' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($openHandleSettings)) -ceq
        [Convert]::ToBase64String($openHandleUpdated)
    )
    Check 'open settings handle creates no rollback artifact' (
        -not [IO.File]::Exists($openHandleTemporary) -and
        -not [IO.File]::Exists($openHandleRestore)
    )

    $commitRaceRoot = Join-Path $TempRoot 'commit-point-settings'
    [void][IO.Directory]::CreateDirectory($commitRaceRoot)
    $commitRaceSettings = Join-Path $commitRaceRoot 'settings.json'
    $commitRaceBackup = Join-Path $commitRaceRoot 'settings.json.bak'
    $commitRaceTemporary = Join-Path $commitRaceRoot '.settings.json.tmp'
    $commitRaceRestore = Join-Path $commitRaceRoot '.settings.json.restore'
    $commitRacePrefix = '{"padding":"'
    $commitRaceSuffix = '"}'
    $commitRacePadding = 8MB - $Utf8NoBom.GetByteCount(
        $commitRacePrefix + $commitRaceSuffix
    )
    $commitRaceBuilder = New-Object System.Text.StringBuilder
    [void]$commitRaceBuilder.Append($commitRacePrefix)
    [void]$commitRaceBuilder.Append(([char]'x'), [int]$commitRacePadding)
    [void]$commitRaceBuilder.Append($commitRaceSuffix)
    $commitRaceOriginal = $Utf8NoBom.GetBytes($commitRaceBuilder.ToString())
    [void]$commitRaceBuilder.Clear()
    $commitRaceUpdated = New-Object byte[] ($commitRaceOriginal.Length)
    [Array]::Copy(
        $commitRaceOriginal,
        0,
        $commitRaceUpdated,
        0,
        $commitRaceOriginal.Length
    )
    $commitRaceUpdated[$commitRacePrefix.Length] = [byte][char]'y'
    [IO.File]::WriteAllBytes($commitRaceSettings, $commitRaceOriginal)
    $commitRaceConcurrent = $Utf8NoBom.GetBytes('{"value":"concurrent-at-commit"}')
    $writerSettings = [Convert]::ToBase64String(
        $Utf8NoBom.GetBytes($commitRaceSettings)
    )
    $writerBackup = [Convert]::ToBase64String(
        $Utf8NoBom.GetBytes($commitRaceBackup)
    )
    $writerBytes = [Convert]::ToBase64String($commitRaceConcurrent)
    $writerCode = (
        '$ErrorActionPreference="Stop";' +
        '$u=New-Object System.Text.UTF8Encoding($false);' +
        '$s=$u.GetString([Convert]::FromBase64String("' + $writerSettings + '"));' +
        '$k=$u.GetString([Convert]::FromBase64String("' + $writerBackup + '"));' +
        '$b=[Convert]::FromBase64String("' + $writerBytes + '");' +
        '$d=[DateTime]::UtcNow.AddSeconds(15);' +
        'while([DateTime]::UtcNow -lt $d){' +
        'if([IO.File]::Exists($k)){try{[IO.File]::WriteAllBytes($s,$b);exit 0}' +
        'catch [IO.IOException]{}}};exit 2'
    )
    $unicode = New-Object System.Text.UnicodeEncoding($false, $false)
    $writerEncoded = [Convert]::ToBase64String($unicode.GetBytes($writerCode))
    $commitRaceWriter = Start-Process -FilePath $PowerShellExe -ArgumentList @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $writerEncoded
    ) -WindowStyle Hidden -PassThru
    $commitRacePlan = [pscustomobject]@{
        Existed = $true
        OriginalBytes = $commitRaceOriginal
        UpdatedBytes = $commitRaceUpdated
        Changed = $true
    }
    $commitRaceRejected = $false
    $commitRaceSucceeded = $false
    try {
        [void](Commit-Settings (
            $commitRaceSettings
        ) $commitRacePlan $commitRaceBackup $commitRaceTemporary $commitRaceRestore)
        $commitRaceSucceeded = $true
    } catch {
        $commitRaceRejected = (
            $_.Exception.Message.Contains('concurrent change') -or
            $_.Exception.Message.Contains('settings changed')
        )
    }
    $commitRaceWriterFinished = $commitRaceWriter.WaitForExit(15000)
    if (-not $commitRaceWriterFinished) { $commitRaceWriter.Kill() }
    $commitRaceWriterExit = -1
    if ($commitRaceWriterFinished) { $commitRaceWriterExit = $commitRaceWriter.ExitCode }
    $commitRaceWriter.Dispose()
    Check 'commit-point concurrent writer completed' (
        $commitRaceWriterFinished -and $commitRaceWriterExit -eq 0
    )
    Check 'commit-point concurrent settings transaction has a safe outcome' (
        $commitRaceRejected -xor $commitRaceSucceeded
    )
    Check 'commit-point concurrent settings bytes preserved' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($commitRaceSettings)) -ceq
        [Convert]::ToBase64String($commitRaceConcurrent)
    )

    $overlapLeaf = '.installer-overlap-' + [guid]::NewGuid().ToString('N')
    $overlapInstall = Join-Path $Repo $overlapLeaf
    $overlapPaths = New-Paths 'overlap-settings'
    $overlapRun = Invoke-Installer $Repo $overlapInstall $overlapPaths.Settings
    Check 'source and install overlap rejected' ($overlapRun.ExitCode -ne 0)
    Check 'overlap rejection creates nothing in source' (-not [IO.Directory]::Exists($overlapInstall))

    $unsafePaths = New-Paths 'unsafe-settings'
    $unsafeInstall = Join-Path $TempRoot 'unsafe%path\coralline'
    $unsafeRun = Invoke-Installer $Repo $unsafeInstall $unsafePaths.Settings
    Check 'percent install path rejected' ($unsafeRun.ExitCode -ne 0)
    Check 'percent path not created' (-not [IO.Directory]::Exists((Join-Path $TempRoot 'unsafe%path')))

    $fakeWorkspace = Join-Path $TempRoot 'fake workspace'
    [void][IO.Directory]::CreateDirectory($fakeWorkspace)
    $marker = Join-Path $fakeWorkspace 'FAKE-RAN'
    [IO.File]::WriteAllBytes((Join-Path $fakeWorkspace 'powershell.exe'), [byte[]](0x4d, 0x5a, 0, 0))
    Write-Utf8 (Join-Path $fakeWorkspace 'powershell.cmd') ('@echo fake>"' + $marker + '"')
    Write-Utf8 (Join-Path $fakeWorkspace 'statusline.cmd') ('@echo fake>"' + $marker + '"')
    $fakeExeHash = Get-FileSha256 (Join-Path $fakeWorkspace 'powershell.exe')
    $sample = $StrictUtf8.GetString([IO.File]::ReadAllBytes((Join-Path $Repo 'test\sample-input.json')))
    $cmdArguments = '/d /s /c "' + $desiredCommand + '"'
    $renderEnvironment = @{
        HOME = $main.Home
        USERPROFILE = $main.Home
        PATH = $fakeWorkspace + ';' + $env:PATH
        CORALLINE_NO_SAMPLE = '1'
    }
    $render = Invoke-CapturedProcess $env:ComSpec $cmdArguments $sample $renderEnvironment $fakeWorkspace 30000
    Check 'registered command cmd.exe E2E exit 0' ($render.ExitCode -eq 0)
    Check 'registered command cmd.exe E2E renders output' (
        $null -ne $render.Stdout -and $render.StdoutBytes.Length -gt 0
    )
    Check 'registered command cmd.exe E2E no stderr' ($render.StderrBytes.Length -eq 0)
    Check 'fake workspace executables never ran' (-not [IO.File]::Exists($marker))
    Check 'fake workspace executable untouched' (
        (Get-FileSha256 (Join-Path $fakeWorkspace 'powershell.exe')) -ceq $fakeExeHash
    )

    $rollback = New-Paths 'rollback'
    $rollbackFresh = Invoke-Installer $Repo $rollback.Install $rollback.Settings
    Check 'rollback fixture fresh install' ($rollbackFresh.ExitCode -eq 0)
    $rollbackSource = Join-Path $TempRoot 'rollback-source'
    Copy-ManagedSource $rollbackSource
    $changedTheme = Join-Path $rollbackSource 'themes\mono.conf'
    [IO.File]::AppendAllText(
        $changedTheme,
        ("`n" + '# rollback test change' + "`n"),
        $Utf8NoBom
    )
    $runtimeBefore = Get-FileSha256 (Join-Path $rollback.Install 'themes\mono.conf')
    $rollbackSettingsText = '{"keep":"original","statusLine":null}'
    Write-Utf8 $rollback.Settings $rollbackSettingsText
    $rollbackSettingsBytes = [IO.File]::ReadAllBytes($rollback.Settings)
    $lock = [IO.File]::Open(
        $rollback.Settings,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $rollbackRun = Invoke-Installer $rollbackSource $rollback.Install $rollback.Settings
    } finally {
        $lock.Dispose()
    }
    Check 'locked settings forces install failure' ($rollbackRun.ExitCode -ne 0)
    Check 'failed settings commit prints no success' (-not $rollbackRun.Stdout.Contains('coralline installed at'))
    Check 'settings failure restores previous runtime' (
        (Get-FileSha256 (Join-Path $rollback.Install 'themes\mono.conf')) -ceq $runtimeBefore
    )
    Check 'settings failure leaves settings byte-identical' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($rollback.Settings)) -ceq
        [Convert]::ToBase64String($rollbackSettingsBytes)
    )

    $junctionTarget = Join-Path $TempRoot 'junction-target'
    $junctionPath = Join-Path $TempRoot 'junction-entry'
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    Write-Utf8 (Join-Path $junctionTarget 'canary.txt') 'keep'
    $junctionCreate = Invoke-CapturedProcess $env:ComSpec (
        '/d /s /c "mklink /J ' + (Quote-ProcessArgument $junctionPath) + ' ' +
        (Quote-ProcessArgument $junctionTarget) + '"'
    ) '' @{} $TempRoot 10000
    if ($junctionCreate.ExitCode -eq 0 -and [IO.Directory]::Exists($junctionPath)) {
        $junctionSettings = (New-Paths 'junction-settings').Settings
        $junctionRun = Invoke-Installer $Repo (Join-Path $junctionPath 'coralline') $junctionSettings
        Check 'reparse component rejected' ($junctionRun.ExitCode -ne 0)
        Check 'reparse canary preserved' (
            [IO.File]::ReadAllText((Join-Path $junctionTarget 'canary.txt'), $StrictUtf8) -ceq 'keep'
        )
        [void](Invoke-CapturedProcess $env:ComSpec (
            '/d /s /c "rmdir ' + (Quote-ProcessArgument $junctionPath) + '"'
        ) '' @{} $TempRoot 10000)
    } else {
        Blocked 'reparse component rejection' 'mklink /J was unavailable in this Windows environment'
    }
} finally {
    if ([IO.Directory]::Exists($TempRoot)) {
        $canonicalTemp = [IO.Path]::GetFullPath($TempRoot)
        $canonicalSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($canonicalTemp.StartsWith($canonicalSystemTemp, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($canonicalTemp).StartsWith('coralline install 測試 & (ps51)-')) {
            Remove-Item -LiteralPath $canonicalTemp -Recurse -Force
        } else {
            [Console]::Error.WriteLine("refusing unexpected test cleanup path: $canonicalTemp")
            $script:Fail++
        }
    }
}

[Console]::Out.WriteLine("RESULT  pass=$($script:Pass) fail=$($script:Fail) blocked=$($script:Blocked)")
if ($script:Fail -gt 0) { exit 1 }
exit 0
