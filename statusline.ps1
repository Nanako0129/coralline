#Requires -Version 5.1
<#
  coralline - native Windows PowerShell statusline for Claude Code.

  This runtime implements the main bar and optional float producer without Bash,
  jq, WSL, or PowerShell 7. Config is read from the same coralline.conf through a
  narrow, non-executing Bash-word parser. Burn uses validated TSV history and
  synced limit state uses compact directories, matching Bash; --subagent renders
  native panel rows.
#>

$SubagentMode = $args.Count -gt 0 -and [string]$args[0] -ceq '--subagent'

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$InputStream = [Console]::OpenStandardInput()
if ($SubagentMode) {
    # Read one byte beyond the limit before allocating a decoded string. This
    # distinguishes an exact-cap stream from a longer one without unbounded I/O.
    $inputCap = 4194304
    $inputBytes = New-Object byte[] ($inputCap + 1)
    $inputLength = 0
    try {
        while ($inputLength -lt $inputBytes.Length) {
            $read = $InputStream.Read($inputBytes, $inputLength, $inputBytes.Length - $inputLength)
            if ($read -le 0) { break }
            $inputLength += $read
        }
        if ($inputLength -gt $inputCap) { [Environment]::Exit(0) }
        $rawInput = $StrictUtf8.GetString($inputBytes, 0, $inputLength)
    } catch { [Environment]::Exit(0) }
} else {
    $InputReader = New-Object System.IO.StreamReader($InputStream, $StrictUtf8, $false, 4096, $false)
    try { $rawInput = $InputReader.ReadToEnd() } catch { $rawInput = '' }
    $InputReader.Dispose()
}

$OutputStream = [Console]::OpenStandardOutput()
$OutputWriter = New-Object System.IO.StreamWriter($OutputStream, $Utf8NoBom, 4096, $false)
$OutputWriter.NewLine = "`n"
$OutputWriter.AutoFlush = $true
$OutputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom

function Glyph([int]$Codepoint) {
    return [System.Char]::ConvertFromUtf32($Codepoint)
}

function Remove-ControlChars([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return [regex]::Replace($Value, '[\u0000-\u001f\u007f-\u009f]', '')
}

function Copy-Config([System.Collections.IDictionary]$Source) {
    $copy = [ordered]@{}
    foreach ($key in $Source.Keys) { $copy[$key] = [string]$Source[$key] }
    return ,$copy
}

$HomeDir = [string]$HOME
if ([string]::IsNullOrEmpty($HomeDir)) { $HomeDir = [Environment]::GetFolderPath('UserProfile') }
$ScriptDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
$ScriptPath = [string]$MyInvocation.MyCommand.Path
# Base for every cross-session store below. Follows CLAUDE_CONFIG_DIR so two
# Claude config directories keep separate burn/limit state instead of
# overwriting each other; unset, it is the historical %USERPROFILE%\.claude.
$CoralineDir = [string]$env:CLAUDE_CONFIG_DIR
if ([string]::IsNullOrEmpty($CoralineDir)) { $CoralineDir = [System.IO.Path]::Combine($HomeDir, '.claude') }
$CoralineDir = [System.IO.Path]::Combine($CoralineDir, 'coralline')
$DefaultFloatFile = [System.IO.Path]::Combine($CoralineDir, 'float.txt')
$DefaultBurnFile = [string]$env:CORALLINE_BURN_FILE
if ([string]::IsNullOrEmpty($DefaultBurnFile)) {
    $DefaultBurnFile = [System.IO.Path]::Combine($CoralineDir, 'burn-5h.tsv')
}
$DefaultRl5File = [string]$env:CORALLINE_RL5H_FILE
if ([string]::IsNullOrEmpty($DefaultRl5File)) {
    $DefaultRl5File = [System.IO.Path]::Combine($CoralineDir, 'limit-5h.tsv')
}
$DefaultRl7File = [string]$env:CORALLINE_RL7D_FILE
if ([string]::IsNullOrEmpty($DefaultRl7File)) {
    $DefaultRl7File = [System.IO.Path]::Combine($CoralineDir, 'limit-7d.tsv')
}

$Defaults = [ordered]@{
    VL_STYLE = 'pill'
    VL_LEAN_SEP = ''
    VL_LEAN_BG = ''
    VL_LEAN_FG = ''
    VL_LEAN_CAP_R = ''
    VL_LEAN_CAP_L = ''
    VL_LAYOUT = 'fixed'
    VL_MAX_LINES = '3'
    VL_WRAP_MARGIN = '4'
    VL_SEGMENTS = 'dir git model ctx limit5h limit7d cost clock'
    VL_SEGMENTS2 = ''
    VL_SEGMENTS3 = ''
    VL_BAR_WIDTH = '5'
    VL_BAR_FILL = (Glyph 0x25B0)
    VL_BAR_EMPTY = (Glyph 0x25B1)
    VL_CTX_GLYPH = (Glyph 0x2B21)
    VL_PROJECT_GLYPH = (Glyph 0x2B22)
    VL_CACHE_GLYPH = (Glyph 0x26C1)
    VL_CLOCK = '12h'
    VL_CLOCK_SECONDS = '1'
    VL_PATH_DEPTH = '4'
    VL_NAME_MAX = '0'
    VL_COST_DECIMALS = '2'
    VL_CTX_ALWAYS_SHOW = '0'
    VL_COST_ALWAYS_SHOW = '0'
    VL_WARN_PCT = '50'
    VL_HOT_PCT = '75'
    VL_ASCII = '0'
    VL_FLOAT = '0'
    VL_FLOAT_SEGMENTS = 'model ctx cost'
    VL_FLOAT_SEP = ('  ' + (Glyph 0x00B7) + '  ')
    VL_FLOAT_FILE = $DefaultFloatFile
    VL_NOCOLOR = '0'

    VL_SUB_SEGMENTS = 'name model ctx elapsed'
    VL_BG_SUB_NAME = ''
    VL_BG_SUB_MODEL = ''
    VL_BG_SUB_CTX = ''
    VL_BG_SUB_ELAPSED = ''
    VL_FG_SUB_TEXT = ''
    VL_FG_SUB_OK = ''
    VL_FG_SUB_HOT = ''
    VL_FG_SUB_DIM = ''
    _VL_SUB_BG_NAME = ''
    _VL_SUB_FG_TEXT = ''
    _VL_SUB_FG_OK = ''
    _VL_SUB_FG_HOT = ''
    _VL_SUB_FG_DIM = ''
    _VL_SUB_FP = ''
    _VL_SUB_BAR = ''

    CORALLINE_BURN_WINDOW = '600'
    VL_BURN_GLYPH = (Glyph 0x2197)
    VL_BG_BURN = ''
    BURN_FILE = $DefaultBurnFile
    BURN_TRIM = '1500'
    VL_LIMIT_SYNC = '0'
    RL5H_FILE = $DefaultRl5File
    RL7D_FILE = $DefaultRl7File
    RL_MAX_5H = '21600'
    RL_MAX_7D = '691200'

    VL_CAP_L = (Glyph 0xE0B6)
    VL_CAP_R = (Glyph 0xE0B4)
    VL_SEP = (Glyph 0xE0B0)

    VL_BG_DIR = '81,166,199'
    VL_BG_PROJECT = ''
    VL_BG_GIT_OK = '65'
    VL_BG_STASH = ''
    VL_BG_GIT_DIRTY = '130'
    VL_BG_MODEL = '173'
    VL_BG_CTX = '238'
    VL_BG_5H = '237'
    VL_BG_7D = '236'
    VL_BG_COST = '212,125,145'
    VL_BG_CLOCK = '70,80,110'
    VL_BG_LINES = '240'
    VL_BG_STYLE = '96'
    VL_BG_DURATION = '60'
    VL_BG_EFFORT = '141'
    VL_BG_NODE = ''
    VL_BG_PYTHON = ''
    VL_BG_CACHE = ''
    VL_BG_BAR = ''
    VL_NODE_GLYPH = (Glyph 0xE718)
    VL_PY_GLYPH = (Glyph 0xE73C)
    VL_RUNTIME_PROBE = '0'

    VL_FG_TEXT = '231'
    VL_FG_DIM = '245'
    VL_FG_OK = '114'
    VL_FG_WARN = '179'
    VL_FG_HOT = '167'
}

$PathConfigKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($key in @('VL_FLOAT_FILE', 'BURN_FILE', 'RL5H_FILE', 'RL7D_FILE')) { [void]$PathConfigKeys.Add($key) }
$ConfigKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($key in $Defaults.Keys) { [void]$ConfigKeys.Add([string]$key) }

function Add-Utf8Text([System.Collections.Generic.List[byte]]$Bytes, [string]$Text) {
    try {
        $encoded = $StrictUtf8.GetBytes($Text)
        $Bytes.AddRange($encoded)
        return $true
    } catch { return $false }
}

function Read-WordChar([string]$Text, [ref]$Index) {
    $i = [int]$Index.Value
    if ($i -ge $Text.Length) { return $null }
    $count = 1
    if ([char]::IsHighSurrogate($Text[$i])) {
        if (($i + 1) -ge $Text.Length -or -not [char]::IsLowSurrogate($Text[$i + 1])) { return $null }
        $count = 2
    } elseif ([char]::IsLowSurrogate($Text[$i])) { return $null }
    $piece = $Text.Substring($i, $count)
    $Index.Value = $i + $count
    return $piece
}

function Decode-ShellWord([string]$Text, [bool]$PathContext) {
    if ($null -eq $Text) { return [pscustomobject]@{ Success = $false; Value = '' } }
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    $i = 0
    $started = $false

    if ($Text.Length -eq 0) { return [pscustomobject]@{ Success = $true; Value = '' } }
    if ($Text[0] -eq ' ' -or $Text[0] -eq "`t") {
        $rest = $Text.TrimStart(' ', "`t")
        if ($rest.Length -eq 0 -or $rest[0] -eq '#') {
            return [pscustomobject]@{ Success = $true; Value = '' }
        }
        return [pscustomobject]@{ Success = $false; Value = '' }
    }

    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($ch -eq ' ' -or $ch -eq "`t") { break }
        $started = $true

        if ($ch -eq "'") {
            $i++
            $closed = $false
            while ($i -lt $Text.Length) {
                if ($Text[$i] -eq "'") { $i++; $closed = $true; break }
                $ri = [ref]$i
                $piece = Read-WordChar $Text $ri
                if ($null -eq $piece) { return [pscustomobject]@{ Success = $false; Value = '' } }
                $i = $ri.Value
                if (-not (Add-Utf8Text $bytes $piece)) { return [pscustomobject]@{ Success = $false; Value = '' } }
            }
            if (-not $closed) { return [pscustomobject]@{ Success = $false; Value = '' } }
            continue
        }

        if ($ch -eq '"') {
            $i++
            $closed = $false
            while ($i -lt $Text.Length) {
                $ch = $Text[$i]
                if ($ch -eq '"') { $i++; $closed = $true; break }
                if ($ch -eq '\') {
                    $i++
                    if ($i -ge $Text.Length) { return [pscustomobject]@{ Success = $false; Value = '' } }
                    $next = $Text[$i]
                    if ($next -eq '"' -or $next -eq '\' -or $next -eq '$' -or $next -eq '`') {
                        if (-not (Add-Utf8Text $bytes ([string]$next))) { return [pscustomobject]@{ Success = $false; Value = '' } }
                        $i++
                        continue
                    }
                    # In Bash double quotes, a backslash before an ordinary
                    # character remains literal together with that character.
                    if (-not (Add-Utf8Text $bytes '\')) { return [pscustomobject]@{ Success = $false; Value = '' } }
                    $ri = [ref]$i
                    $piece = Read-WordChar $Text $ri
                    if ($null -eq $piece -or -not (Add-Utf8Text $bytes $piece)) {
                        return [pscustomobject]@{ Success = $false; Value = '' }
                    }
                    $i = $ri.Value
                    continue
                }
                if ($ch -eq '$') {
                    if (-not $PathContext) { return [pscustomobject]@{ Success = $false; Value = '' } }
                    if ($Text.Substring($i).StartsWith('${HOME}', [System.StringComparison]::Ordinal)) { $i += 7 }
                    elseif (
                        $Text.Substring($i).StartsWith('$HOME', [System.StringComparison]::Ordinal) -and
                        ($i + 5 -ge $Text.Length -or [string]$Text[$i + 5] -notmatch '[A-Za-z0-9_]')
                    ) { $i += 5 }
                    else { return [pscustomobject]@{ Success = $false; Value = '' } }
                    if (-not (Add-Utf8Text $bytes $HomeDir)) { return [pscustomobject]@{ Success = $false; Value = '' } }
                    continue
                }
                if ($ch -eq '`') { return [pscustomobject]@{ Success = $false; Value = '' } }
                $ri = [ref]$i
                $piece = Read-WordChar $Text $ri
                if ($null -eq $piece) { return [pscustomobject]@{ Success = $false; Value = '' } }
                $i = $ri.Value
                if (-not (Add-Utf8Text $bytes $piece)) { return [pscustomobject]@{ Success = $false; Value = '' } }
            }
            if (-not $closed) { return [pscustomobject]@{ Success = $false; Value = '' } }
            continue
        }

        if ($ch -eq '$' -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq "'") {
            $i += 2
            $closed = $false
            while ($i -lt $Text.Length) {
                $ch = $Text[$i]
                if ($ch -eq "'") { $i++; $closed = $true; break }
                if ($ch -ne '\') {
                    $ri = [ref]$i
                    $piece = Read-WordChar $Text $ri
                    if ($null -eq $piece) { return [pscustomobject]@{ Success = $false; Value = '' } }
                    $i = $ri.Value
                    if (-not (Add-Utf8Text $bytes $piece)) { return [pscustomobject]@{ Success = $false; Value = '' } }
                    continue
                }

                $i++
                if ($i -ge $Text.Length) { return [pscustomobject]@{ Success = $false; Value = '' } }
                $esc = $Text[$i]
                $i++
                $byteValue = -1
                switch ($esc) {
                    'a' { $byteValue = 7 }
                    'b' { $byteValue = 8 }
                    'e' { $byteValue = 27 }
                    'E' { $byteValue = 27 }
                    'f' { $byteValue = 12 }
                    'n' { $byteValue = 10 }
                    'r' { $byteValue = 13 }
                    't' { $byteValue = 9 }
                    'v' { $byteValue = 11 }
                    '\' { $byteValue = 92 }
                    "'" { $byteValue = 39 }
                    '"' { $byteValue = 34 }
                    default {
                        if ($esc -ge '0' -and $esc -le '7') {
                            $digits = [string]$esc
                            while ($digits.Length -lt 3 -and $i -lt $Text.Length -and $Text[$i] -ge '0' -and $Text[$i] -le '7') {
                                $digits += $Text[$i]
                                $i++
                            }
                            try { $byteValue = [Convert]::ToInt32($digits, 8) } catch { $byteValue = -1 }
                            if ($byteValue -gt 255) { $byteValue = -1 }
                        } elseif ($esc -eq 'x') {
                            $digits = ''
                            while ($digits.Length -lt 2 -and $i -lt $Text.Length -and $Text[$i] -match '[0-9A-Fa-f]') {
                                $digits += $Text[$i]
                                $i++
                            }
                            if ($digits.Length -eq 0) { return [pscustomobject]@{ Success = $false; Value = '' } }
                            try { $byteValue = [Convert]::ToInt32($digits, 16) } catch { $byteValue = -1 }
                        } elseif ($esc -eq 'u' -or $esc -eq 'U') {
                            $need = 4
                            if ($esc -eq 'U') { $need = 8 }
                            if (($i + $need) -gt $Text.Length) { return [pscustomobject]@{ Success = $false; Value = '' } }
                            $digits = $Text.Substring($i, $need)
                            if ($digits -notmatch ('^[0-9A-Fa-f]{' + $need + '}$')) { return [pscustomobject]@{ Success = $false; Value = '' } }
                            $i += $need
                            try { $cp = [Convert]::ToInt32($digits, 16) } catch { return [pscustomobject]@{ Success = $false; Value = '' } }
                            if ($cp -gt 0x10FFFF -or ($cp -ge 0xD800 -and $cp -le 0xDFFF)) {
                                return [pscustomobject]@{ Success = $false; Value = '' }
                            }
                            if (-not (Add-Utf8Text $bytes ([char]::ConvertFromUtf32($cp)))) {
                                return [pscustomobject]@{ Success = $false; Value = '' }
                            }
                            continue
                        } else { return [pscustomobject]@{ Success = $false; Value = '' } }
                    }
                }
                if ($byteValue -lt 0 -or $byteValue -gt 255) { return [pscustomobject]@{ Success = $false; Value = '' } }
                [void]$bytes.Add([byte]$byteValue)
            }
            if (-not $closed) { return [pscustomobject]@{ Success = $false; Value = '' } }
            continue
        }

        if ($ch -eq '\') {
            $i++
            if ($i -ge $Text.Length) { return [pscustomobject]@{ Success = $false; Value = '' } }
            $ri = [ref]$i
            $piece = Read-WordChar $Text $ri
            if ($null -eq $piece) { return [pscustomobject]@{ Success = $false; Value = '' } }
            $i = $ri.Value
            if (-not (Add-Utf8Text $bytes $piece)) { return [pscustomobject]@{ Success = $false; Value = '' } }
            continue
        }

        if ($ch -eq '$') {
            if (-not $PathContext) { return [pscustomobject]@{ Success = $false; Value = '' } }
            if ($Text.Substring($i).StartsWith('${HOME}', [System.StringComparison]::Ordinal)) { $i += 7 }
            elseif (
                $Text.Substring($i).StartsWith('$HOME', [System.StringComparison]::Ordinal) -and
                ($i + 5 -ge $Text.Length -or [string]$Text[$i + 5] -notmatch '[A-Za-z0-9_]')
            ) { $i += 5 }
            else { return [pscustomobject]@{ Success = $false; Value = '' } }
            if (-not (Add-Utf8Text $bytes $HomeDir)) { return [pscustomobject]@{ Success = $false; Value = '' } }
            continue
        }

        if ($ch -eq '`' -or $ch -eq ';' -or $ch -eq '|' -or $ch -eq '&' -or $ch -eq '<' -or $ch -eq '>' -or $ch -eq '(' -or $ch -eq ')') {
            return [pscustomobject]@{ Success = $false; Value = '' }
        }

        $ri = [ref]$i
        $piece = Read-WordChar $Text $ri
        if ($null -eq $piece) { return [pscustomobject]@{ Success = $false; Value = '' } }
        $i = $ri.Value
        if (-not (Add-Utf8Text $bytes $piece)) { return [pscustomobject]@{ Success = $false; Value = '' } }
    }

    if (-not $started) { return [pscustomobject]@{ Success = $false; Value = '' } }
    while ($i -lt $Text.Length -and ($Text[$i] -eq ' ' -or $Text[$i] -eq "`t")) { $i++ }
    if ($i -lt $Text.Length -and $Text[$i] -ne '#') { return [pscustomobject]@{ Success = $false; Value = '' } }

    try { $value = $StrictUtf8.GetString($bytes.ToArray()) } catch { return [pscustomobject]@{ Success = $false; Value = '' } }
    if ($PathContext -and $value.StartsWith('~', [System.StringComparison]::Ordinal)) {
        if ($value -eq '~') { $value = $HomeDir }
        elseif ($value.StartsWith('~/', [System.StringComparison]::Ordinal) -or $value.StartsWith('~\', [System.StringComparison]::Ordinal)) {
            $value = $HomeDir.TrimEnd('\', '/') + $value.Substring(1)
        } else { return [pscustomobject]@{ Success = $false; Value = '' } }
    }
    return [pscustomobject]@{ Success = $true; Value = $value }
}

function Test-DosDeviceComponent([string]$Component) {
    if ([string]::IsNullOrEmpty($Component)) { return $false }
    $name = $Component.TrimEnd('.', ' ')
    $dot = $name.IndexOf('.')
    if ($dot -ge 0) { $name = $name.Substring(0, $dot) }
    return $name -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])$'
}

function Test-LocalPathSyntax([string]$Path, [ref]$Normalized) {
    if ([string]::IsNullOrEmpty($Path) -or $Path.Length -gt 4096) { return $false }
    if ($Path -match '[\u0000-\u001f\u007f-\u009f]') { return $false }
    if ($Path.StartsWith('\\', [System.StringComparison]::Ordinal) -or $Path.StartsWith('//', [System.StringComparison]::Ordinal)) { return $false }
    if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or $Path.StartsWith('\\.\', [System.StringComparison]::Ordinal) -or $Path.StartsWith('//?/', [System.StringComparison]::Ordinal) -or $Path.StartsWith('//./', [System.StringComparison]::Ordinal)) { return $false }

    $p = $Path
    if ($p -match '^/([A-Za-z])(?:/|$)') {
        $drive = $Matches[1].ToUpperInvariant()
        $p = $drive + ':\' + $p.Substring(2).TrimStart('/')
    }
    $p = $p.Replace('/', '\')
    if ($p.StartsWith('\', [System.StringComparison]::Ordinal)) { return $false }

    $colon = $p.IndexOf(':')
    if ($colon -ge 0 -and ($colon -ne 1 -or $p.Length -lt 3 -or -not [char]::IsLetter($p[0]) -or $p[2] -ne '\' -or $p.IndexOf(':', 2) -ge 0)) { return $false }
    try { $root = [System.IO.Path]::GetPathRoot($p) } catch { return $false }
    $rest = $p
    if (-not [string]::IsNullOrEmpty($root)) { $rest = $p.Substring($root.Length) }
    foreach ($component in $rest.Split(@('\'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        if ($component -eq '.' -or $component -eq '..') { continue }
        if ($component.EndsWith('.') -or $component.EndsWith(' ')) { return $false }
        if ($component -match '[<>"\|\?\*:]') { return $false }
        if (Test-DosDeviceComponent $component) { return $false }
    }
    $Normalized.Value = $p
    return $true
}

function ConvertTo-LocalFullPath([string]$Path, [string]$BaseDir) {
    if ([string]::IsNullOrEmpty($Path) -or $Path.Length -gt 4096) { return $null }
    $p = ''
    $normalized = $null
    if (-not (Test-LocalPathSyntax $Path ([ref]$normalized))) { return $null }
    $p = $normalized
    try {
        if (-not [System.IO.Path]::IsPathRooted($p)) { $p = [System.IO.Path]::Combine($BaseDir, $p) }
        $full = [System.IO.Path]::GetFullPath($p)
    } catch { return $null }
    if ([string]::IsNullOrEmpty($full) -or $full.Length -gt 4096 -or $full.StartsWith('\\', [System.StringComparison]::Ordinal)) { return $null }
    return $full
}

function Test-PathInside([string]$Path, [string]$Root) {
    if ([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($Root)) { return $false }
    $trimmed = $Root.TrimEnd('\')
    if ($trimmed.Length -eq 2 -and $trimmed[1] -eq ':') { $trimmed += '\' }
    if ($Path.Equals($trimmed, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $trimmed
    if (-not $prefix.EndsWith('\', [System.StringComparison]::Ordinal)) { $prefix += '\' }
    return $Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-NoReparseComponents([string]$Path) {
    try { $root = [System.IO.Path]::GetPathRoot($Path) } catch { return $false }
    if ([string]::IsNullOrEmpty($root)) { return $false }
    $parts = $Path.Substring($root.Length).Split(@('\'), [System.StringSplitOptions]::RemoveEmptyEntries)
    $current = $root
    for ($i=0; $i -lt $parts.Length; $i++) {
        $current = [System.IO.Path]::Combine($current, $parts[$i])
        try { $attrs = [System.IO.File]::GetAttributes($current) }
        catch [System.IO.FileNotFoundException] { return $true }
        catch [System.IO.DirectoryNotFoundException] { return $true }
        catch { return $false }
        if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ($i -lt ($parts.Length - 1) -and ($attrs -band [System.IO.FileAttributes]::Directory) -eq 0) { return $false }
    }
    return $true
}

function Test-SafeRegularFile([string]$Path) {
    if (-not (Test-NoReparseComponents $Path)) { return $false }
    try { $attrs = [System.IO.File]::GetAttributes($Path) } catch { return $false }
    if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    if (($attrs -band [System.IO.FileAttributes]::Directory) -ne 0) { return $false }
    return $true
}

function Read-StrictUtf8File([string]$Path) {
    try {
        $attrs = [System.IO.File]::GetAttributes($Path)
        if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or ($attrs -band [System.IO.FileAttributes]::Directory) -ne 0) { return $null }
        $info = New-Object System.IO.FileInfo($Path)
        if ($info.Length -gt 1048576) { return $null }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $text = $StrictUtf8.GetString($bytes)
        if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
        return $text
    } catch { return $null }
}

function Import-ConfigFile(
    [string]$Path,
    [System.Collections.IDictionary]$BaseConfig,
    [System.Collections.Generic.HashSet[string]]$BaseAssignments,
    [hashtable]$State,
    [int]$Depth,
    [string[]]$ApprovedRoots
) {
    $failed = [pscustomobject]@{ Success = $false; Config = $BaseConfig; Assignments = $BaseAssignments }
    if ($Depth -gt 8) { return $failed }
    if ($State.Visited.Contains($Path)) { return $failed }
    [void]$State.Visited.Add($Path)
    if (-not (Test-SafeRegularFile $Path)) { return $failed }
    $text = Read-StrictUtf8File $Path
    if ($null -eq $text) { return $failed }

    $candidate = Copy-Config $BaseConfig
    $candidateAssignments = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($assignedName in $BaseAssignments) { [void]$candidateAssignments.Add($assignedName) }
    $rootFloatAuthorized = $false
    $stack = New-Object System.Collections.ArrayList
    $active = $true
    $valid = $true
    $lines = [regex]::Split($text, "`r`n|`n|`r")

    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t.Length -eq 0 -or $t.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
        $statement = $line.TrimStart(' ', "`t")

        if ($t -match '^if[ \t]+\[[ \t]+"\$\{REMORA_ACTIVE:-0\}"[ \t]+(=|!=)[ \t]+"([^"\r\n]*)"[ \t]+\];[ \t]+then$') {
            $op = $Matches[1]
            $literal = $Matches[2]
            $envValue = [string]$env:REMORA_ACTIVE
            if ([string]::IsNullOrEmpty($envValue)) { $envValue = '0' }
            $condition = $envValue -ceq $literal
            if ($op -eq '!=') { $condition = -not $condition }
            $frame = [pscustomobject]@{ ParentActive = $active; Condition = $condition; ElseSeen = $false }
            [void]$stack.Add($frame)
            $active = $active -and $condition
            continue
        }
        if ($t -match '^if(?:[ \t]|$)') { $valid = $false; break }
        if ($t -eq 'else') {
            if ($stack.Count -eq 0) { $valid = $false; break }
            $frame = $stack[$stack.Count - 1]
            if ($frame.ElseSeen) { $valid = $false; break }
            $frame.ElseSeen = $true
            $active = $frame.ParentActive -and (-not $frame.Condition)
            continue
        }
        if ($t -eq 'fi') {
            if ($stack.Count -eq 0) { $valid = $false; break }
            $frame = $stack[$stack.Count - 1]
            $active = $frame.ParentActive
            $stack.RemoveAt($stack.Count - 1)
            continue
        }
        if (-not $active) { continue }

        if ($statement -eq '.' -or $statement -match '^\.[ \t]+') {
            if ([int]$State.IncludeCount -ge 16) { continue }
            $State.IncludeCount = [int]$State.IncludeCount + 1
            $wordText = ''
            if ($statement.Length -gt 1) { $wordText = $statement.Substring(1).TrimStart(' ', "`t") }
            $decoded = Decode-ShellWord $wordText $true
            if (-not $decoded.Success) { continue }
            $includePath = ConvertTo-LocalFullPath $decoded.Value ([System.IO.Path]::GetDirectoryName($Path))
            if ([string]::IsNullOrEmpty($includePath)) { continue }
            if (-not [System.IO.Path]::GetExtension($includePath).Equals('.conf', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $inside = $false
            foreach ($root in $ApprovedRoots) {
                if (Test-PathInside $includePath $root) { $inside = $true; break }
            }
            if (-not $inside) { continue }
            $child = Import-ConfigFile $includePath $candidate $candidateAssignments $State ($Depth + 1) $ApprovedRoots
            if ($child.Success) {
                $candidate = $child.Config
                $candidateAssignments = $child.Assignments
            }
            continue
        }

        if ($statement -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $name = $Matches[1]
            $raw = $Matches[2]
            $pathContext = $PathConfigKeys.Contains($name) -or $name -ieq 'VL_FLOAT_FILE'
            $decoded = Decode-ShellWord $raw $pathContext
            if (-not $decoded.Success) { $valid = $false; break }
            if ($pathContext -and $decoded.Value -match '[\x00-\x1f\u007f-\u009f]') { $valid = $false; break }
            if ($name -ieq 'VL_FLOAT_FILE') {
                if ($Depth -eq 0 -and $name -ceq 'VL_FLOAT_FILE') {
                    $candidate['VL_FLOAT_FILE'] = $decoded.Value
                    [void]$candidateAssignments.Add($name)
                    $rootFloatAuthorized = $true
                }
                continue
            }
            # Bash variable names are case-sensitive. OrderedDictionary is not,
            # so ignore unknown and case-variant keys instead of letting them
            # overwrite a supported setting.
            if ($ConfigKeys.Contains($name)) {
                $candidate[$name] = $decoded.Value
                [void]$candidateAssignments.Add($name)
            }
            continue
        }

        $valid = $false
        break
    }

    if ($stack.Count -ne 0) { $valid = $false }
    if (-not $valid) { return $failed }
    return [pscustomobject]@{
        Success = $true
        Config = $candidate
        Assignments = $candidateAssignments
        FloatFileAuthorized = ($Depth -eq 0 -and $rootFloatAuthorized)
    }
}

$Cfg = Copy-Config $Defaults
$ConfigAssignments = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$FloatFileRootAuthorized = $false
$ConfigInput = [string]$env:CORALLINE_CONFIG
if ([string]::IsNullOrEmpty($ConfigInput)) { $ConfigInput = [System.IO.Path]::Combine($HomeDir, '.claude\coralline.conf') }
$ConfigPath = ConvertTo-LocalFullPath $ConfigInput ([Environment]::CurrentDirectory)
if (-not [string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigRoot = [System.IO.Path]::GetDirectoryName($ConfigPath)
    $ThemesRoot = ConvertTo-LocalFullPath ([System.IO.Path]::Combine($ScriptDir, 'themes')) $ScriptDir
    $approved = @($ConfigRoot)
    if (-not [string]::IsNullOrEmpty($ThemesRoot)) { $approved += $ThemesRoot }
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $state = @{ IncludeCount = 0; Visited = $visited }
    $parsed = Import-ConfigFile $ConfigPath $Cfg $ConfigAssignments $state 0 $approved
    if ($parsed.Success) {
        $Cfg = $parsed.Config
        $ConfigAssignments = $parsed.Assignments
        $FloatFileRootAuthorized = [bool]$parsed.FloatFileAuthorized
    }
}
$ConfigVisitedPaths = @()
if ($null -ne $visited) {
    foreach ($visitedPath in $visited) { $ConfigVisitedPaths += [string]$visitedPath }
}

# Config never supplies terminal controls. The renderer is the sole ANSI source.
foreach ($key in @($Cfg.Keys)) { $Cfg[$key] = Remove-ControlChars ([string]$Cfg[$key]) }

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$IntegerStyle = [System.Globalization.NumberStyles]::Integer
$FloatStyle = [System.Globalization.NumberStyles]::Float

function Get-BoundedInt([string]$Raw, [int]$Fallback, [int]$Min, [int]$Max) {
    $value = 0
    if (-not [int]::TryParse($Raw, $IntegerStyle, $Invariant, [ref]$value)) { return $Fallback }
    if ($value -lt $Min -or $value -gt $Max) { return $Fallback }
    return $value
}

function Try-BoundedDouble([string]$Raw, [double]$Min, [double]$Max, [ref]$Result) {
    $value = 0.0
    if ([string]::IsNullOrEmpty($Raw)) { return $false }
    if (-not [double]::TryParse($Raw, $FloatStyle, $Invariant, [ref]$value)) { return $false }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt $Min -or $value -gt $Max) { return $false }
    $Result.Value = $value
    return $true
}

function Test-Color([string]$Spec) {
    if ([string]::IsNullOrEmpty($Spec)) { return $true }
    if ($Spec -match '^([0-9]{1,3})$') {
        $n = 0
        return [int]::TryParse($Matches[1], $IntegerStyle, $Invariant, [ref]$n) -and $n -ge 0 -and $n -le 255
    }
    if ($Spec -match '^([0-9]{1,3}),([0-9]{1,3}),([0-9]{1,3})$') {
        foreach ($part in @($Matches[1], $Matches[2], $Matches[3])) {
            $n = 0
            if (-not [int]::TryParse($part, $IntegerStyle, $Invariant, [ref]$n) -or $n -lt 0 -or $n -gt 255) { return $false }
        }
        return $true
    }
    return $false
}

$Cfg.VL_BAR_WIDTH = [string](Get-BoundedInt $Cfg.VL_BAR_WIDTH ([int]$Defaults.VL_BAR_WIDTH) 0 64)
$Cfg.VL_PATH_DEPTH = [string](Get-BoundedInt $Cfg.VL_PATH_DEPTH ([int]$Defaults.VL_PATH_DEPTH) 1 256)
$Cfg.VL_NAME_MAX = [string](Get-BoundedInt $Cfg.VL_NAME_MAX ([int]$Defaults.VL_NAME_MAX) 0 4096)
$Cfg.VL_COST_DECIMALS = [string](Get-BoundedInt $Cfg.VL_COST_DECIMALS ([int]$Defaults.VL_COST_DECIMALS) 0 9)
$Cfg.VL_WARN_PCT = [string](Get-BoundedInt $Cfg.VL_WARN_PCT ([int]$Defaults.VL_WARN_PCT) 0 100)
$Cfg.VL_HOT_PCT = [string](Get-BoundedInt $Cfg.VL_HOT_PCT ([int]$Defaults.VL_HOT_PCT) 0 100)
$Cfg.VL_MAX_LINES = [string](Get-BoundedInt $Cfg.VL_MAX_LINES ([int]$Defaults.VL_MAX_LINES) 1 64)
$Cfg.VL_WRAP_MARGIN = [string](Get-BoundedInt $Cfg.VL_WRAP_MARGIN ([int]$Defaults.VL_WRAP_MARGIN) 0 32767)
if ([int]$Cfg.VL_HOT_PCT -lt [int]$Cfg.VL_WARN_PCT) {
    $Cfg.VL_WARN_PCT = $Defaults.VL_WARN_PCT
    $Cfg.VL_HOT_PCT = $Defaults.VL_HOT_PCT
}
foreach ($key in @($Cfg.Keys | Where-Object { $_ -like 'VL_BG_*' -or $_ -like 'VL_FG_*' })) {
    if (-not (Test-Color $Cfg[$key])) { $Cfg[$key] = $Defaults[$key] }
}
foreach ($key in @('_VL_SUB_BG_NAME', '_VL_SUB_FG_TEXT', '_VL_SUB_FG_OK', '_VL_SUB_FG_HOT', '_VL_SUB_FG_DIM')) {
    if (-not (Test-Color $Cfg[$key])) { $Cfg[$key] = '' }
}
if (-not (Test-Color $Cfg.VL_LEAN_BG)) { $Cfg.VL_LEAN_BG = '' }
if (-not (Test-Color $Cfg.VL_LEAN_FG)) { $Cfg.VL_LEAN_FG = '' }

$Cfg.VL_STYLE = switch -CaseSensitive ([string]$Cfg.VL_STYLE) {
    'pill' { 'pill'; break }
    'lean' { 'lean'; break }
    'classic' { 'classic'; break }
    default { 'pill' }
}
$Cfg.VL_LAYOUT = switch -CaseSensitive ([string]$Cfg.VL_LAYOUT) {
    'fixed' { 'fixed'; break }
    'auto' { 'auto'; break }
    default { 'fixed' }
}

# Adopt bundled subagent inks only while the palette and painted ground still
# match the theme that supplied them. Exact assignment tracking preserves Bash's
# distinction between an unset public knob and an explicitly empty override.
$stockSubFingerprint = '81,166,199|231|114|167|245'
$stockSubBar = '|'
$candidateFingerprint = $stockSubFingerprint
$candidateBar = $stockSubBar
if ($ConfigAssignments.Contains('_VL_SUB_FP')) { $candidateFingerprint = [string]$Cfg._VL_SUB_FP }
if ($ConfigAssignments.Contains('_VL_SUB_BAR')) { $candidateBar = [string]$Cfg._VL_SUB_BAR }
$adoptSubPalette = -not $ConfigAssignments.Contains('VL_BG_SUB_NAME') -and [string]::IsNullOrEmpty([string]$Cfg.VL_LEAN_FG)
if ($Cfg.VL_STYLE -ceq 'lean') {
    if ([string]::IsNullOrEmpty([string]$Cfg.VL_LEAN_BG)) { $adoptSubPalette = $false }
    if (([string]$Cfg.VL_BG_BAR + '|' + [string]$Cfg.VL_LEAN_BG) -cne $candidateBar) { $adoptSubPalette = $false }
} elseif ($Cfg.VL_STYLE -ceq 'classic') {
    if (([string]$Cfg.VL_BG_BAR + '|' + [string]$Cfg.VL_LEAN_BG) -cne $candidateBar) { $adoptSubPalette = $false }
}
$liveSubFingerprint = [string]$Cfg.VL_BG_DIR + '|' + [string]$Cfg.VL_FG_TEXT + '|' + [string]$Cfg.VL_FG_OK + '|' + [string]$Cfg.VL_FG_HOT + '|' + [string]$Cfg.VL_FG_DIM
if ($liveSubFingerprint -cne $candidateFingerprint) { $adoptSubPalette = $false }
if ($adoptSubPalette) {
    if (-not $ConfigAssignments.Contains('VL_BG_SUB_NAME')) {
        $Cfg.VL_BG_SUB_NAME = if ($ConfigAssignments.Contains('_VL_SUB_BG_NAME')) { $Cfg._VL_SUB_BG_NAME } else { '68,68,68' }
    }
    if (-not $ConfigAssignments.Contains('VL_FG_SUB_TEXT')) {
        $Cfg.VL_FG_SUB_TEXT = if ($ConfigAssignments.Contains('_VL_SUB_FG_TEXT')) { $Cfg._VL_SUB_FG_TEXT } else { '255,255,255' }
    }
    if (-not $ConfigAssignments.Contains('VL_FG_SUB_OK')) {
        $Cfg.VL_FG_SUB_OK = if ($ConfigAssignments.Contains('_VL_SUB_FG_OK')) { $Cfg._VL_SUB_FG_OK } else { '' }
    }
    if (-not $ConfigAssignments.Contains('VL_FG_SUB_HOT')) {
        $Cfg.VL_FG_SUB_HOT = if ($ConfigAssignments.Contains('_VL_SUB_FG_HOT')) { $Cfg._VL_SUB_FG_HOT } else { '231,157,157' }
    }
    if (-not $ConfigAssignments.Contains('VL_FG_SUB_DIM')) {
        $Cfg.VL_FG_SUB_DIM = if ($ConfigAssignments.Contains('_VL_SUB_FG_DIM')) { $Cfg._VL_SUB_FG_DIM } else { '177,177,177' }
    }
}

# Bash applies ASCII first, then classic's lean defaults, then lean overrides.
if ($Cfg.VL_ASCII -eq '1') {
    $Cfg.VL_CAP_L = ''
    $Cfg.VL_CAP_R = ''
    $Cfg.VL_SEP = ''
    $Cfg.VL_BAR_FILL = '#'
    $Cfg.VL_BAR_EMPTY = '-'
    $Cfg.VL_NODE_GLYPH = 'node'
    $Cfg.VL_PY_GLYPH = 'py'
}
if ($Cfg.VL_STYLE -eq 'classic') {
    $Cfg.VL_STYLE = 'lean'
    if ([string]::IsNullOrEmpty($Cfg.VL_LEAN_BG)) { $Cfg.VL_LEAN_BG = if ([string]::IsNullOrEmpty($Cfg.VL_BG_BAR)) { '238' } else { $Cfg.VL_BG_BAR } }
    if ([string]::IsNullOrEmpty($Cfg.VL_LEAN_CAP_R)) { $Cfg.VL_LEAN_CAP_R = $Cfg.VL_SEP }
}
if ($Cfg.VL_STYLE -eq 'lean') {
    $Cfg.VL_CAP_L = ''
    $Cfg.VL_CAP_R = ''
    $Cfg.VL_FG_TEXT = $Cfg.VL_LEAN_FG
}

$NoColor = $Cfg.VL_NOCOLOR -eq '1'
$Esc = [char]27
$Rst = "$Esc[0m"
$Bold = "$Esc[1m"
$Norm = "$Esc[22m"
$G = @{
    Branch = Glyph 0x2387
    Diamond = Glyph 0x25C6
    Flag = Glyph 0x2691
    Dot = Glyph 0x2299
    Pencil = Glyph 0x270E
    Hourglass = Glyph 0x29D6
    Psi = Glyph 0x03C8
    Ahead = Glyph 0x21E1
    Behind = Glyph 0x21E3
    Ellipsis = Glyph 0x2026
    Up = Glyph 0x2191
    Down = Glyph 0x2193
    Reset = Glyph 0x21BA
    Check = Glyph 0x2713
    BurnTo = Glyph 0x21E2
}

function Get-Fg([string]$Spec) {
    if ($NoColor -or [string]::IsNullOrEmpty($Spec)) { return '' }
    if ($Spec.Contains(',')) {
        $p = $Spec.Split(',')
        return "$Esc[38;2;$($p[0]);$($p[1]);$($p[2])m"
    }
    return "$Esc[38;5;${Spec}m"
}

function Get-Bg([string]$Spec) {
    if ($NoColor -or [string]::IsNullOrEmpty($Spec)) { return '' }
    if ($Spec.Contains(',')) {
        $p = $Spec.Split(',')
        return "$Esc[48;2;$($p[0]);$($p[1]);$($p[2])m"
    }
    return "$Esc[48;5;${Spec}m"
}

function New-Bar([int]$Pct, [int]$Width) {
    if ($Pct -lt 0) { $Pct = 0 }
    if ($Pct -gt 100) { $Pct = 100 }
    $filled = [int][math]::Floor(($Pct * $Width + 50) / 100)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $Width) { $filled = $Width }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $filled; $i++) { [void]$sb.Append($Cfg.VL_BAR_FILL) }
    for ($i = $filled; $i -lt $Width; $i++) { [void]$sb.Append($Cfg.VL_BAR_EMPTY) }
    return $sb.ToString()
}

function Format-Tok([string]$Raw) {
    if ([string]::IsNullOrEmpty($Raw)) { return '0' }
    if ($Raw -notmatch '^[0-9]+$') { return $Raw }
    $n = 0L
    if (-not [long]::TryParse($Raw, $IntegerStyle, $Invariant, [ref]$n)) { return '0' }
    if ($n -ge 1000000) {
        $scale = 1000000L
        $tenthScale = 100000L
        $suffix = 'M'
    } elseif ($n -ge 1000) {
        $scale = 1000L
        $tenthScale = 100L
        $suffix = 'k'
    } else { return [string]$n }
    $remainder = 0L
    $whole = [Math]::DivRem($n, $scale, [ref]$remainder)
    $unused = 0L
    $tenth = [Math]::DivRem($remainder, $tenthScale, [ref]$unused)
    return ('{0}.{1}{2}' -f $whole, $tenth, $suffix)
}

function Get-PctValue([string]$Raw, [ref]$Result) {
    if ([string]::IsNullOrEmpty($Raw)) { return $false }
    $value = 0.0
    if (-not (Try-BoundedDouble $Raw -1000000 1000000 ([ref]$value))) { $value = 0 }
    if ($value -lt 0) { $value = 0 }
    if ($value -gt 100) { $value = 100 }
    $Result.Value = [int][math]::Round($value, [System.MidpointRounding]::ToEven)
    return $true
}

function Get-PctFg([int]$Pct) {
    if ($Pct -ge [int]$Cfg.VL_HOT_PCT) { return $Cfg.VL_FG_HOT }
    if ($Pct -ge [int]$Cfg.VL_WARN_PCT) { return $Cfg.VL_FG_WARN }
    return $Cfg.VL_FG_OK
}

function Get-Trunc([string]$S, [int]$Max) {
    if ($null -eq $S) { return '' }
    if ($Max -le 0) { return $S }
    $offsets = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 0; $i -lt $S.Length) {
        [void]$offsets.Add($i)
        if ([char]::IsHighSurrogate($S[$i]) -and ($i + 1) -lt $S.Length -and [char]::IsLowSurrogate($S[$i + 1])) { $i += 2 }
        else { $i++ }
    }
    $count = $offsets.Count
    if ($count -le $Max) { return $S }
    if ($Max -lt 3) {
        $end = if ($Max -lt $count) { $offsets[$Max] } else { $S.Length }
        return $S.Substring(0, $end)
    }
    $head = [int][math]::Floor(($Max - 1) / 2)
    $tail = $Max - 1 - $head
    $headEnd = if ($head -lt $count) { $offsets[$head] } else { $S.Length }
    $tailStart = $offsets[$count - $tail]
    return $S.Substring(0, $headEnd) + $G.Ellipsis + $S.Substring($tailStart)
}

function New-StrictJsonNode([string]$Kind, $Value) {
    return [pscustomobject]@{ Kind = $Kind; Value = $Value }
}

function Skip-StrictJsonWhitespace([hashtable]$State) {
    while ($State.Index -lt $State.Text.Length) {
        $ch = $State.Text[$State.Index]
        if ($ch -ne ' ' -and $ch -ne "`t" -and $ch -ne "`n" -and $ch -ne "`r") { break }
        $State.Index++
    }
}

function Read-StrictJsonString([hashtable]$State) {
    if ($State.Index -ge $State.Text.Length -or $State.Text[$State.Index] -ne '"') {
        $State.Valid = $false
        return $null
    }
    $State.Index++
    $builder = New-Object System.Text.StringBuilder
    :jsonStringCharacters while ($State.Index -lt $State.Text.Length) {
        $ch = $State.Text[$State.Index]
        $State.Index++
        if ($ch -eq '"') { return $builder.ToString() }
        if ($ch -eq '\') {
            if ($State.Index -ge $State.Text.Length) { $State.Valid = $false; return $null }
            $escape = $State.Text[$State.Index]
            $State.Index++
            switch -CaseSensitive ([string]$escape) {
                '"' { [void]$builder.Append('"'); continue jsonStringCharacters }
                '\' { [void]$builder.Append('\'); continue jsonStringCharacters }
                '/' { [void]$builder.Append('/'); continue jsonStringCharacters }
                'b' { [void]$builder.Append([char]8); continue jsonStringCharacters }
                'f' { [void]$builder.Append([char]12); continue jsonStringCharacters }
                'n' { [void]$builder.Append([char]10); continue jsonStringCharacters }
                'r' { [void]$builder.Append([char]13); continue jsonStringCharacters }
                't' { [void]$builder.Append([char]9); continue jsonStringCharacters }
                'u' {
                    if (($State.Index + 4) -gt $State.Text.Length) { $State.Valid = $false; return $null }
                    $hex = $State.Text.Substring($State.Index, 4)
                    if ($hex -notmatch '\A[0-9A-Fa-f]{4}\z') { $State.Valid = $false; return $null }
                    $State.Index += 4
                    try { $code = [Convert]::ToInt32($hex, 16) } catch { $State.Valid = $false; return $null }
                    if ($code -ge 0xD800 -and $code -le 0xDBFF) {
                        if (($State.Index + 6) -gt $State.Text.Length -or $State.Text[$State.Index] -ne '\' -or $State.Text[$State.Index + 1] -cne 'u') {
                            $State.Valid = $false
                            return $null
                        }
                        $lowHex = $State.Text.Substring($State.Index + 2, 4)
                        if ($lowHex -notmatch '\A[0-9A-Fa-f]{4}\z') { $State.Valid = $false; return $null }
                        try { $low = [Convert]::ToInt32($lowHex, 16) } catch { $State.Valid = $false; return $null }
                        if ($low -lt 0xDC00 -or $low -gt 0xDFFF) { $State.Valid = $false; return $null }
                        [void]$builder.Append([char]$code)
                        [void]$builder.Append([char]$low)
                        $State.Index += 6
                        continue jsonStringCharacters
                    }
                    if ($code -ge 0xDC00 -and $code -le 0xDFFF) { $State.Valid = $false; return $null }
                    [void]$builder.Append([char]$code)
                    continue jsonStringCharacters
                }
                default { $State.Valid = $false; return $null }
            }
        }
        $codepoint = [int][char]$ch
        if ($codepoint -le 0x1F) { $State.Valid = $false; return $null }
        if ([char]::IsHighSurrogate($ch)) {
            if ($State.Index -ge $State.Text.Length -or -not [char]::IsLowSurrogate($State.Text[$State.Index])) {
                $State.Valid = $false
                return $null
            }
            [void]$builder.Append($ch)
            [void]$builder.Append($State.Text[$State.Index])
            $State.Index++
            continue jsonStringCharacters
        }
        if ([char]::IsLowSurrogate($ch)) { $State.Valid = $false; return $null }
        [void]$builder.Append($ch)
    }
    $State.Valid = $false
    return $null
}

function Read-StrictJsonNumber([hashtable]$State) {
    $start = [int]$State.Index
    if ($State.Text[$State.Index] -eq '-') {
        $State.Index++
        if ($State.Index -ge $State.Text.Length) { $State.Valid = $false; return $null }
    }
    if ($State.Text[$State.Index] -eq '0') {
        $State.Index++
    } elseif ($State.Text[$State.Index] -ge '1' -and $State.Text[$State.Index] -le '9') {
        $State.Index++
        while ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -ge '0' -and $State.Text[$State.Index] -le '9') { $State.Index++ }
    } else {
        $State.Valid = $false
        return $null
    }
    if ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -eq '.') {
        $State.Index++
        $fractionStart = [int]$State.Index
        while ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -ge '0' -and $State.Text[$State.Index] -le '9') { $State.Index++ }
        if ($State.Index -eq $fractionStart) { $State.Valid = $false; return $null }
    }
    if ($State.Index -lt $State.Text.Length -and ($State.Text[$State.Index] -eq 'e' -or $State.Text[$State.Index] -eq 'E')) {
        $State.Index++
        if ($State.Index -lt $State.Text.Length -and ($State.Text[$State.Index] -eq '+' -or $State.Text[$State.Index] -eq '-')) { $State.Index++ }
        $exponentStart = [int]$State.Index
        while ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -ge '0' -and $State.Text[$State.Index] -le '9') { $State.Index++ }
        if ($State.Index -eq $exponentStart) { $State.Valid = $false; return $null }
    }
    return $State.Text.Substring($start, $State.Index - $start)
}

function Read-StrictJsonValueStart(
    [hashtable]$State,
    [System.Collections.Generic.List[object]]$Stack
) {
    if ($State.Index -ge $State.Text.Length) { $State.Valid = $false; return $null }
    if ([int]$State.NodeCount -ge 32768) { $State.Valid = $false; return $null }
    $State.NodeCount = [int]$State.NodeCount + 1
    $ch = $State.Text[$State.Index]
    if ($ch -eq '"') {
        $value = Read-StrictJsonString $State
        if (-not $State.Valid) { return $null }
        return New-StrictJsonNode 'string' $value
    }
    if ($ch -eq '{') {
        if ($Stack.Count -ge 128) { $State.Valid = $false; return $null }
        $State.Index++
        $members = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $node = New-StrictJsonNode 'object' $members
        [void]$Stack.Add([pscustomobject]@{ Type='object'; State='keyOrEnd'; Node=$node; Seen=$seen; Key='' })
        return $node
    }
    if ($ch -eq '[') {
        if ($Stack.Count -ge 128) { $State.Valid = $false; return $null }
        $State.Index++
        $items = New-Object 'System.Collections.Generic.List[object]'
        $node = New-StrictJsonNode 'array' $items
        [void]$Stack.Add([pscustomobject]@{ Type='array'; State='valueOrEnd'; Node=$node })
        return $node
    }
    if ($ch -eq '-' -or ($ch -ge '0' -and $ch -le '9')) {
        $number = Read-StrictJsonNumber $State
        if (-not $State.Valid) { return $null }
        return New-StrictJsonNode 'number' $number
    }
    if (($State.Index + 4) -le $State.Text.Length -and $State.Text.Substring($State.Index, 4) -ceq 'true') {
        $State.Index += 4
        return New-StrictJsonNode 'bool' $true
    }
    if (($State.Index + 5) -le $State.Text.Length -and $State.Text.Substring($State.Index, 5) -ceq 'false') {
        $State.Index += 5
        return New-StrictJsonNode 'bool' $false
    }
    if (($State.Index + 4) -le $State.Text.Length -and $State.Text.Substring($State.Index, 4) -ceq 'null') {
        $State.Index += 4
        return New-StrictJsonNode 'null' $null
    }
    $State.Valid = $false
    return $null
}

function Read-StrictJsonValue([hashtable]$State) {
    $stack = New-Object 'System.Collections.Generic.List[object]'
    $root = Read-StrictJsonValueStart $State $stack
    if (-not $State.Valid) { return $null }
    while ($stack.Count -gt 0 -and $State.Valid) {
        $frame = $stack[$stack.Count - 1]
        Skip-StrictJsonWhitespace $State
        if ($frame.Type -ceq 'object') {
            if ($frame.State -ceq 'keyOrEnd' -or $frame.State -ceq 'key') {
                if ($frame.State -ceq 'keyOrEnd' -and $State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -eq '}') {
                    $State.Index++
                    $stack.RemoveAt($stack.Count - 1)
                    continue
                }
                if ($State.Index -ge $State.Text.Length -or $State.Text[$State.Index] -ne '"') { $State.Valid = $false; break }
                $key = Read-StrictJsonString $State
                if (-not $State.Valid -or -not $frame.Seen.Add($key)) { $State.Valid = $false; break }
                $frame.Key = $key
                $frame.State = 'colon'
                continue
            }
            if ($frame.State -ceq 'colon') {
                if ($State.Index -ge $State.Text.Length -or $State.Text[$State.Index] -ne ':') { $State.Valid = $false; break }
                $State.Index++
                $frame.State = 'value'
                continue
            }
            if ($frame.State -ceq 'value') {
                Skip-StrictJsonWhitespace $State
                $node = Read-StrictJsonValueStart $State $stack
                if (-not $State.Valid) { break }
                $frame.Node.Value.Add([string]$frame.Key, $node)
                $frame.State = 'commaOrEnd'
                continue
            }
            if ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -eq ',') {
                $State.Index++
                $frame.State = 'key'
                continue
            }
            if ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -eq '}') {
                $State.Index++
                $stack.RemoveAt($stack.Count - 1)
                continue
            }
            $State.Valid = $false
            break
        }

        if ($frame.State -ceq 'valueOrEnd' -or $frame.State -ceq 'value') {
            if ($frame.State -ceq 'valueOrEnd' -and $State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -eq ']') {
                $State.Index++
                $stack.RemoveAt($stack.Count - 1)
                continue
            }
            $node = Read-StrictJsonValueStart $State $stack
            if (-not $State.Valid) { break }
            [void]$frame.Node.Value.Add($node)
            $frame.State = 'commaOrEnd'
            continue
        }
        if ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -eq ',') {
            $State.Index++
            $frame.State = 'value'
            continue
        }
        if ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -eq ']') {
            $State.Index++
            $stack.RemoveAt($stack.Count - 1)
            continue
        }
        $State.Valid = $false
    }
    if (-not $State.Valid) { return $null }
    return $root
}

function Read-StrictJsonStream([string]$Text) {
    $state = @{ Text=$Text; Index=0; Valid=$true; NodeCount=0 }
    $last = $null
    $count = 0
    Skip-StrictJsonWhitespace $state
    while ($state.Index -lt $state.Text.Length -and $state.Valid) {
        $last = Read-StrictJsonValue $state
        if (-not $state.Valid) { break }
        $count++
        Skip-StrictJsonWhitespace $state
    }
    return [pscustomobject]@{ Success=($state.Valid -and $count -gt 0 -and $state.Index -eq $state.Text.Length); Count=$count; Last=$last }
}

function Get-StrictJsonMember($Node, [string]$Name) {
    if ($null -eq $Node -or $Node.Kind -cne 'object') { return $null }
    $value = $null
    if (-not $Node.Value.TryGetValue($Name, [ref]$value)) { return $null }
    return $value
}

function Convert-StrictJsonNumber([string]$Raw) {
    # jq's decimal tostring preserves coefficient scale. It switches to
    # scientific form when the decimal quantum is positive or adjusts below -6.
    $match = [regex]::Match($Raw, '\A(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?\z')
    if (-not $match.Success) { return $null }
    $sign = $match.Groups[1].Value
    $fraction = $match.Groups[3].Value
    $exponentText = if ($match.Groups[4].Success) { $match.Groups[4].Value } else { '0' }
    $explicitExponent = [bigint]::Zero
    if (-not [bigint]::TryParse($exponentText, $IntegerStyle, $Invariant, [ref]$explicitExponent)) { return $null }

    $quantum = $explicitExponent - [bigint]([int]$fraction.Length)
    $coefficient = ($match.Groups[2].Value + $fraction).TrimStart('0')
    if ([string]::IsNullOrEmpty($coefficient)) { $coefficient = '0' }
    $maxAdjusted = [bigint]999999999
    $minQuantum = [bigint](-1147483646)
    $adjusted = $quantum + [bigint]([int]$coefficient.Length - 1)

    if ($coefficient -ceq '0') {
        if ($quantum -gt $maxAdjusted) { $quantum = $maxAdjusted }
        elseif ($quantum -lt $minQuantum) { $quantum = $minQuantum }
        $adjusted = $quantum
    } else {
        if ($adjusted -gt $maxAdjusted) { return $sign + '1.7976931348623157e+308' }
        if ($quantum -lt $minQuantum) {
            $discard = $minQuantum - $quantum
            if ($discard -gt [bigint]([int]$coefficient.Length)) {
                $coefficient = '0'
            } else {
                $discardCount = [int]$discard
                $retainedCount = $coefficient.Length - $discardCount
                $retainedText = if ($retainedCount -gt 0) { $coefficient.Substring(0, $retainedCount) } else { '0' }
                $rounded = [bigint]::Zero
                if (-not [bigint]::TryParse($retainedText, $IntegerStyle, $Invariant, [ref]$rounded)) { return $null }
                if ($coefficient[$retainedCount] -ge '5') { $rounded += [bigint]::One }
                $coefficient = $rounded.ToString($Invariant)
            }
            $quantum = $minQuantum
            $adjusted = $quantum + [bigint]([int]$coefficient.Length - 1)
        }
    }

    if ($quantum -gt [bigint]::Zero -or $adjusted -lt [bigint](-6)) {
        $mantissa = [string]$coefficient[0]
        if ($coefficient.Length -gt 1) { $mantissa += '.' + $coefficient.Substring(1) }
        $shownExponent = $adjusted.ToString($Invariant)
        if ($adjusted -ge [bigint]::Zero) { $shownExponent = '+' + $shownExponent }
        return $sign + $mantissa + 'E' + $shownExponent
    }

    $point = [int]([bigint]([int]$coefficient.Length) + $quantum)
    if ($point -eq $coefficient.Length) { return $sign + $coefficient }
    if ($point -gt 0) {
        return $sign + $coefficient.Substring(0, $point) + '.' + $coefficient.Substring($point)
    }
    return $sign + '0.' + (('0' * (-$point)) -join '') + $coefficient
}

function Convert-StrictJsonScalar($Node, [int]$ByteCap) {
    if ($null -eq $Node) { return [pscustomobject]@{ Valid=$false; Value='' } }
    switch -CaseSensitive ([string]$Node.Kind) {
        'null' { $value = ''; break }
        'string' { $value = [string]$Node.Value; break }
        'number' {
            $rawNumber = [string]$Node.Value
            try {
                if ($StrictUtf8.GetByteCount($rawNumber) -gt $ByteCap) { return [pscustomobject]@{ Valid=$false; Value='' } }
            } catch { return [pscustomobject]@{ Valid=$false; Value='' } }
            $value = Convert-StrictJsonNumber $rawNumber
            if ($null -eq $value) { return [pscustomobject]@{ Valid=$false; Value='' } }
            break
        }
        'bool' { $value = if ([bool]$Node.Value) { 'true' } else { 'false' }; break }
        default { return [pscustomobject]@{ Valid=$false; Value='' } }
    }
    $value = Remove-ControlChars $value
    try {
        if ($StrictUtf8.GetByteCount($value) -gt $ByteCap) { return [pscustomobject]@{ Valid=$false; Value='' } }
    } catch { return [pscustomobject]@{ Valid=$false; Value='' } }
    return [pscustomobject]@{ Valid=$true; Value=$value }
}

function ConvertTo-StrictJsonString([string]$Value) {
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    :jsonEscapeCharacters for ($i = 0; $i -lt $Value.Length; $i++) {
        $ch = $Value[$i]
        $code = [int][char]$ch
        switch ($code) {
            8 { [void]$builder.Append('\b'); continue jsonEscapeCharacters }
            9 { [void]$builder.Append('\t'); continue jsonEscapeCharacters }
            10 { [void]$builder.Append('\n'); continue jsonEscapeCharacters }
            12 { [void]$builder.Append('\f'); continue jsonEscapeCharacters }
            13 { [void]$builder.Append('\r'); continue jsonEscapeCharacters }
            34 { [void]$builder.Append('\"'); continue jsonEscapeCharacters }
            92 { [void]$builder.Append('\\'); continue jsonEscapeCharacters }
        }
        if ($code -lt 0x20) {
            [void]$builder.Append(('\u{0:x4}' -f $code))
            continue
        }
        [void]$builder.Append($ch)
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Read-BoundedStrictUtf8RegularFile([string]$Path, [int]$ByteCap) {
    if (-not (Test-SafeRegularFile $Path)) { return $null }
    try {
        $info = New-Object System.IO.FileInfo($Path)
        if ($info.Length -gt $ByteCap) { return $null }
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        try {
            $bytes = New-Object byte[] ($ByteCap + 1)
            $length = 0
            while ($length -lt $bytes.Length) {
                $read = $stream.Read($bytes, $length, $bytes.Length - $length)
                if ($read -le 0) { break }
                $length += $read
            }
            if ($length -gt $ByteCap) { return $null }
            return $StrictUtf8.GetString($bytes, 0, $length)
        } finally { $stream.Dispose() }
    } catch { return $null }
}

function Get-SubagentSidecarPath([string]$Transcript, [string]$Id) {
    if ([string]::IsNullOrEmpty($Transcript) -or $Transcript.Length -gt 4096) { return $null }
    if ([string]::IsNullOrEmpty($Id) -or $Id -match '[<>:"/\\|?*]') { return $null }
    $path = $Transcript.Replace('/', '\')
    if ($path -notmatch '\A[A-Za-z]:\\') { return $null }
    if (-not $path.EndsWith('.jsonl', [System.StringComparison]::Ordinal)) { return $null }
    if ($path.StartsWith('\\', [System.StringComparison]::Ordinal) -or $path.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or $path.StartsWith('\\.\', [System.StringComparison]::Ordinal)) { return $null }
    if ($path.IndexOf(':', 2) -ge 0 -or $path -match '[\u0000-\u001f\u007f-\u009f]') { return $null }
    $rest = $path.Substring(3)
    if ([string]::IsNullOrEmpty($rest)) { return $null }
    $components = $rest.Split('\')
    foreach ($component in $components) {
        if ([string]::IsNullOrEmpty($component) -or $component -eq '.' -or $component -eq '..') { return $null }
        if ($component.EndsWith('.') -or $component.EndsWith(' ') -or ($component -match '[<>":|?*]')) { return $null }
        if (Test-DosDeviceComponent $component) { return $null }
    }
    try {
        $fullTranscript = [System.IO.Path]::GetFullPath($path)
        if ($fullTranscript.Length -gt 4096 -or [System.IO.Path]::GetPathRoot($fullTranscript).Length -ne 3) { return $null }
        $base = $fullTranscript.Substring(0, $fullTranscript.Length - 6)
        if ([string]::IsNullOrEmpty($base)) { return $null }
        $expectedDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, 'subagents'))
        $candidate = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($expectedDir, ('agent-' + $Id + '.meta.json')))
    } catch { return $null }
    if ($expectedDir.Length -gt 4096 -or $candidate.Length -gt 4096) { return $null }
    if (-not [System.IO.Path]::GetDirectoryName($candidate).Equals($expectedDir, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-PathInside $candidate $expectedDir) -or $candidate.Equals($expectedDir, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-NoReparseComponents $fullTranscript) -or -not (Test-NoReparseComponents $expectedDir) -or -not (Test-NoReparseComponents $candidate)) { return $null }
    return $candidate
}

function Get-SubagentRole([string]$Transcript, [string]$Id) {
    $path = Get-SubagentSidecarPath $Transcript $Id
    if ([string]::IsNullOrEmpty($path)) { return '' }
    $text = Read-BoundedStrictUtf8RegularFile $path 65536
    if ($null -eq $text) { return '' }
    $parsed = Read-StrictJsonStream $text
    if (-not $parsed.Success -or $parsed.Count -ne 1 -or $null -eq $parsed.Last -or $parsed.Last.Kind -cne 'object') { return '' }
    $roleResult = Convert-StrictJsonScalar (Get-StrictJsonMember $parsed.Last 'agentType') 16384
    if (-not $roleResult.Valid -or $roleResult.Value -notmatch '\A[A-Za-z0-9._:]+\z') { return '' }
    return [string]$roleResult.Value
}

function Get-SubagentModelShort([string]$Model) {
    if (-not $Model.StartsWith('claude-', [System.StringComparison]::Ordinal)) { return $Model }
    $value = $Model.Substring(7)
    if ($value -match '-[0-9]{8}\z') { $value = $value.Substring(0, $value.Length - 9) }
    $dash = $value.IndexOf('-')
    if ($dash -le 0 -or $dash -ge ($value.Length - 1)) { return $Model }
    $family = $value.Substring(0, $dash)
    $version = $value.Substring($dash + 1)
    if ($version -notmatch '\A[0-9-]+\z') { return $Model }
    switch -CaseSensitive ($family) {
        'fable' { $family = 'Fable'; break }
        'opus' { $family = 'Opus'; break }
        'sonnet' { $family = 'Sonnet'; break }
        'haiku' { $family = 'Haiku'; break }
        default { return $Model }
    }
    return $family + ' ' + $version.Replace('-', '.')
}

function Try-SubagentUnsigned([string]$Raw, [ref]$Value) {
    if ($Raw -notmatch '\A[0-9]{1,16}\z') { return $false }
    $parsed = 0L
    if (-not [long]::TryParse($Raw, $IntegerStyle, $Invariant, [ref]$parsed) -or $parsed -gt 9999999999999999L) { return $false }
    $Value.Value = $parsed
    return $true
}

function Get-SubagentEpoch([string]$Raw) {
    if ($Raw -match '\A[0-9]{1,16}\z') {
        $value = 0L
        if (-not [long]::TryParse($Raw, $IntegerStyle, $Invariant, [ref]$value)) { return $null }
        if ($Raw.Length -ge 13) {
            $unused = 0L
            $value = [Math]::DivRem($value, 1000L, [ref]$unused)
        }
        if ($value -lt 0 -or $value -gt 253402300799L) { return $null }
        return $value
    }
    # Canonical grammar is YYYY-MM-DDTHH:mm:ss[.digits]Z. Fractions are
    # validated but intentionally discarded because elapsed renders seconds.
    if ($Raw -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z\z') { return $null }
    $year = 0
    $month = 0
    $day = 0
    $hour = 0
    $minute = 0
    $second = 0
    if (
        -not [int]::TryParse($Raw.Substring(0, 4), $IntegerStyle, $Invariant, [ref]$year) -or
        -not [int]::TryParse($Raw.Substring(5, 2), $IntegerStyle, $Invariant, [ref]$month) -or
        -not [int]::TryParse($Raw.Substring(8, 2), $IntegerStyle, $Invariant, [ref]$day) -or
        -not [int]::TryParse($Raw.Substring(11, 2), $IntegerStyle, $Invariant, [ref]$hour) -or
        -not [int]::TryParse($Raw.Substring(14, 2), $IntegerStyle, $Invariant, [ref]$minute) -or
        -not [int]::TryParse($Raw.Substring(17, 2), $IntegerStyle, $Invariant, [ref]$second)
    ) { return $null }
    if ($month -lt 1 -or $month -gt 12 -or $hour -gt 23 -or $minute -gt 59 -or $second -gt 59) { return $null }
    $monthDays = @(31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    if (($year % 4) -eq 0 -and (($year % 100) -ne 0 -or ($year % 400) -eq 0)) {
        $monthDays[1] = 29
    }
    if ($day -lt 1 -or $day -gt $monthDays[$month - 1]) { return $null }

    $shiftedYear = [long]$year
    if ($month -le 2) { $shiftedYear-- }
    $eraNumerator = $shiftedYear
    if ($shiftedYear -lt 0) { $eraNumerator -= 399L }
    $unused = 0L
    $era = [Math]::DivRem($eraNumerator, 400L, [ref]$unused)
    $yearOfEra = $shiftedYear - ($era * 400L)
    $adjustedMonth = [long]$month + 9L
    if ($month -gt 2) { $adjustedMonth = [long]$month - 3L }
    $dayOfYear = [Math]::DivRem((153L * $adjustedMonth) + 2L, 5L, [ref]$unused) + [long]$day - 1L
    $quarters = [Math]::DivRem($yearOfEra, 4L, [ref]$unused)
    $centuries = [Math]::DivRem($yearOfEra, 100L, [ref]$unused)
    $dayOfEra = ($yearOfEra * 365L) + $quarters - $centuries + $dayOfYear
    $days = ($era * 146097L) + $dayOfEra - 719468L
    $epoch = ($days * 86400L) + ([long]$hour * 3600L) + ([long]$minute * 60L) + [long]$second
    if ($epoch -gt 253402300799L) { return $null }
    return $epoch
}

function Format-SubagentDuration([long]$Seconds) {
    $hours = [Math]::Floor($Seconds / 3600)
    $minutes = [Math]::Floor(($Seconds % 3600) / 60)
    $secondsLeft = $Seconds % 60
    if ($hours -gt 0) { return ('{0}h{1:00}m{2:00}s' -f $hours, $minutes, $secondsLeft) }
    if ($minutes -gt 0) { return ('{0}m{1:00}s' -f $minutes, $secondsLeft) }
    return "${Seconds}s"
}

function Add-SubagentSegment(
    [System.Collections.Generic.List[string]]$Backgrounds,
    [System.Collections.Generic.List[string]]$Texts,
    [string]$Background,
    [string]$Text
) {
    [void]$Backgrounds.Add($Background)
    [void]$Texts.Add($Text)
}

function Render-SubagentSegments(
    [System.Collections.Generic.List[string]]$Backgrounds,
    [System.Collections.Generic.List[string]]$Texts
) {
    if ($Backgrounds.Count -eq 0) { return '' }
    if ($Cfg.VL_STYLE -ceq 'lean') {
        $leanBackground = ''
        if (-not [string]::IsNullOrEmpty([string]$Cfg.VL_LEAN_BG)) { $leanBackground = Get-Bg $Cfg.VL_LEAN_BG }
        $out = ''
        if (-not [string]::IsNullOrEmpty($leanBackground) -and -not [string]::IsNullOrEmpty([string]$Cfg.VL_LEAN_CAP_L)) {
            $out = $Rst + (Get-Fg $Cfg.VL_LEAN_BG) + $Cfg.VL_LEAN_CAP_L
        }
        for ($i = 0; $i -lt $Backgrounds.Count; $i++) {
            $out += $Rst + $leanBackground + (Get-Fg $Backgrounds[$i]) + $Texts[$i]
            if ($i -lt ($Backgrounds.Count - 1)) { $out += $Rst + $leanBackground + $Cfg.VL_LEAN_SEP }
        }
        if (-not [string]::IsNullOrEmpty($leanBackground) -and -not [string]::IsNullOrEmpty([string]$Cfg.VL_LEAN_CAP_R)) {
            $out += $Rst + (Get-Fg $Cfg.VL_LEAN_BG) + $Cfg.VL_LEAN_CAP_R
        }
        return $out + $Rst
    }
    $out = $Rst + (Get-Fg $Backgrounds[0]) + $Cfg.VL_CAP_L
    for ($i = 0; $i -lt $Backgrounds.Count; $i++) {
        $out += (Get-Bg $Backgrounds[$i]) + $Texts[$i]
        if ($i -lt ($Backgrounds.Count - 1)) {
            $out += (Get-Bg $Backgrounds[$i + 1]) + (Get-Fg $Backgrounds[$i]) + $Cfg.VL_SEP
        }
    }
    return $out + $Rst + (Get-Fg $Backgrounds[$Backgrounds.Count - 1]) + $Cfg.VL_CAP_R + $Rst
}

function Invoke-SubagentMode([string]$InputText) {
    $stream = Read-StrictJsonStream $InputText
    if (-not $stream.Success -or $null -eq $stream.Last -or $stream.Last.Kind -cne 'object') { return }
    $tasks = Get-StrictJsonMember $stream.Last 'tasks'
    if ($null -eq $tasks -or $tasks.Kind -cne 'array' -or $tasks.Value.Count -gt 1024) { return }
    $transcriptResult = Convert-StrictJsonScalar (Get-StrictJsonMember $stream.Last 'transcript_path') 16384
    $transcript = ''
    if ($transcriptResult.Valid -and $transcriptResult.Value.Length -le 4096) { $transcript = [string]$transcriptResult.Value }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $lines = New-Object 'System.Collections.Generic.List[string]'

    foreach ($task in $tasks.Value) {
        if ($null -eq $task -or $task.Kind -cne 'object') { continue }
        $idResult = Convert-StrictJsonScalar (Get-StrictJsonMember $task 'id') 16384
        if (-not $idResult.Valid -or [string]::IsNullOrEmpty([string]$idResult.Value)) { continue }
        $id = [string]$idResult.Value
        $fields = @{}
        foreach ($fieldName in @('name','label','description','type','status','startTime','model','contextWindowSize','tokenCount')) {
            $result = Convert-StrictJsonScalar (Get-StrictJsonMember $task $fieldName) 16384
            if ($result.Valid) { $fields[$fieldName] = [string]$result.Value } else { $fields[$fieldName] = '' }
        }
        $role = ''
        if ($fields.type -ceq 'local_agent') { $role = Get-SubagentRole $transcript $id }
        $backgrounds = New-Object 'System.Collections.Generic.List[string]'
        $texts = New-Object 'System.Collections.Generic.List[string]'
        $segmentList = [string]$Cfg.VL_SUB_SEGMENTS
        $segmentNames = @()
        if (-not [string]::IsNullOrWhiteSpace($segmentList)) { $segmentNames = @([regex]::Split($segmentList.Trim(), '\s+')) }

        foreach ($segmentName in $segmentNames) {
            switch -CaseSensitive ($segmentName) {
                'name' {
                    $identity = if (-not [string]::IsNullOrEmpty($fields.name)) { $fields.name } else { $role }
                    $detail = if (-not [string]::IsNullOrEmpty($fields.label)) { $fields.label } else { $fields.description }
                    if (-not [string]::IsNullOrEmpty($fields.name) -and -not [string]::IsNullOrEmpty($role) -and $fields.name -cne $role) {
                        $identity = $fields.name + ' (' + $role + ')'
                    }
                    if (-not [string]::IsNullOrEmpty($identity)) {
                        $label = $identity
                        if (-not [string]::IsNullOrEmpty($detail) -and $detail -cne $fields.name -and $detail -cne $role) { $label += ' ' + [char]0x00B7 + ' ' + $detail }
                    } elseif (-not [string]::IsNullOrEmpty($detail)) { $label = $detail }
                    else { $label = $fields.type }
                    if ([string]::IsNullOrEmpty($label)) { break }
                    switch -CaseSensitive ($fields.status) {
                        { $_ -ceq 'running' -or $_ -ceq 'in_progress' -or $_ -ceq 'active' } {
                            $color = if ([string]::IsNullOrEmpty([string]$Cfg.VL_FG_SUB_TEXT)) { $Cfg.VL_FG_TEXT } else { $Cfg.VL_FG_SUB_TEXT }
                            break
                        }
                        { $_ -ceq 'completed' -or $_ -ceq 'success' -or $_ -ceq 'done' } {
                            $color = if ([string]::IsNullOrEmpty([string]$Cfg.VL_FG_SUB_OK)) { $Cfg.VL_FG_OK } else { $Cfg.VL_FG_SUB_OK }
                            break
                        }
                        { $_ -ceq 'failed' -or $_ -ceq 'error' -or $_ -ceq 'cancelled' } {
                            $color = if ([string]::IsNullOrEmpty([string]$Cfg.VL_FG_SUB_HOT)) { $Cfg.VL_FG_HOT } else { $Cfg.VL_FG_SUB_HOT }
                            break
                        }
                        default { $color = if ([string]::IsNullOrEmpty([string]$Cfg.VL_FG_SUB_DIM)) { $Cfg.VL_FG_DIM } else { $Cfg.VL_FG_SUB_DIM } }
                    }
                    $shown = Get-Trunc $label ([int]$Cfg.VL_NAME_MAX)
                    $background = if ([string]::IsNullOrEmpty([string]$Cfg.VL_BG_SUB_NAME)) { $Cfg.VL_BG_DIR } else { $Cfg.VL_BG_SUB_NAME }
                    Add-SubagentSegment $backgrounds $texts $background ($Bold + (Get-Fg $color) + ' ' + $shown + ' ' + $Norm)
                    break
                }
                'model' {
                    if ([string]::IsNullOrEmpty($fields.model)) { break }
                    $background = if ([string]::IsNullOrEmpty([string]$Cfg.VL_BG_SUB_MODEL)) { $Cfg.VL_BG_MODEL } else { $Cfg.VL_BG_SUB_MODEL }
                    Add-SubagentSegment $backgrounds $texts $background ($Bold + (Get-Fg $Cfg.VL_FG_TEXT) + ' ' + $G.Diamond + ' ' + (Get-SubagentModelShort $fields.model) + ' ' + $Norm)
                    break
                }
                'ctx' {
                    $token = 0L
                    if (-not (Try-SubagentUnsigned $fields.tokenCount ([ref]$token))) { break }
                    $tokenText = Format-Tok ($token.ToString($Invariant))
                    $window = 0L
                    $background = if ([string]::IsNullOrEmpty([string]$Cfg.VL_BG_SUB_CTX)) { $Cfg.VL_BG_CTX } else { $Cfg.VL_BG_SUB_CTX }
                    if ((Try-SubagentUnsigned $fields.contextWindowSize ([ref]$window)) -and $window -gt 0) {
                        $unused = 0L
                        $percentage = [Math]::DivRem(($token * 100L), $window, [ref]$unused)
                        if ($percentage -gt 100) { $percentage = 100 }
                        $bar = New-Bar ([int]$percentage) ([int]$Cfg.VL_BAR_WIDTH)
                        Add-SubagentSegment $backgrounds $texts $background ((Get-Fg (Get-PctFg ([int]$percentage))) + ' ' + $Cfg.VL_CTX_GLYPH + ' ' + $bar + ' ' + $percentage + '% ' + (Get-Fg $Cfg.VL_FG_DIM) + $tokenText + ' ')
                    } else {
                        Add-SubagentSegment $backgrounds $texts $background ((Get-Fg $Cfg.VL_FG_DIM) + ' ' + $Cfg.VL_CTX_GLYPH + ' ' + $tokenText + ' ')
                    }
                    break
                }
                'elapsed' {
                    if ([string]::IsNullOrEmpty($fields.startTime)) { break }
                    $epoch = Get-SubagentEpoch $fields.startTime
                    if ($null -eq $epoch -or $epoch -gt $now) { break }
                    $background = if ([string]::IsNullOrEmpty([string]$Cfg.VL_BG_SUB_ELAPSED)) { $Cfg.VL_BG_DURATION } else { $Cfg.VL_BG_SUB_ELAPSED }
                    Add-SubagentSegment $backgrounds $texts $background ((Get-Fg $Cfg.VL_FG_TEXT) + ' ' + [char]0x29D6 + ' ' + (Format-SubagentDuration ($now - [long]$epoch)) + ' ')
                    break
                }
            }
        }
        if ($backgrounds.Count -eq 0) { continue }
        $content = Render-SubagentSegments $backgrounds $texts
        try { if ($StrictUtf8.GetByteCount($content) -gt 65536) { continue } } catch { continue }
        $line = '{"id":' + (ConvertTo-StrictJsonString $id) + ',"content":' + (ConvertTo-StrictJsonString $content) + '}'
        try { if (($StrictUtf8.GetByteCount($line) + 1) -gt 524288) { continue } } catch { continue }
        [void]$lines.Add($line)
    }
    foreach ($line in $lines) { $OutputWriter.WriteLine($line) }
}

if ($SubagentMode) {
    try { Invoke-SubagentMode $rawInput } catch { }
    $OutputWriter.Flush()
    $OutputWriter.Dispose()
    exit 0
}

function ConvertTo-Epoch([string]$Raw) {
    if ([string]::IsNullOrEmpty($Raw)) { return $null }
    $numeric = 0.0
    if (Try-BoundedDouble $Raw 0 253402300799 ([ref]$numeric)) { return [long][math]::Floor($numeric) }
    $dto = [DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ([DateTimeOffset]::TryParse($Raw, $Invariant, $styles, [ref]$dto)) { return $dto.ToUnixTimeSeconds() }
    return $null
}

$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Mutable burn TSV and compact limit state. Percentages are integer milli-percent
# and all midpoint decisions use exact Int64 quotient/remainder arithmetic.
function ConvertTo-StatePct([string]$Raw) {
    if ([string]::IsNullOrEmpty($Raw)) { return $null }
    $match = [regex]::Match($Raw, '\A(0|[1-9][0-9]?|100)(?:\.([0-9]{1,6}))?\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) { return $null }
    $whole = 0
    if (-not [int]::TryParse($match.Groups[1].Value, $IntegerStyle, $Invariant, [ref]$whole)) { return $null }
    $fraction = $match.Groups[2].Value
    if ($whole -eq 100 -and $fraction -match '[1-9]') { return $null }
    $six = ($fraction + '000000').Substring(0, 6)
    $keep = 0
    $rest = 0
    if (-not [int]::TryParse($six.Substring(0, 3), $IntegerStyle, $Invariant, [ref]$keep)) { return $null }
    if (-not [int]::TryParse($six.Substring(3, 3), $IntegerStyle, $Invariant, [ref]$rest)) { return $null }
    $milli = $whole * 1000 + $keep
    if ($rest -gt 500 -or ($rest -eq 500 -and ($milli % 2) -eq 1)) { $milli++ }
    if ($milli -lt 0 -or $milli -gt 100000) { return $null }
    $q = 0L
    $r = 0L
    $q = [Math]::DivRem([long]$milli, 1000L, [ref]$r)
    return [pscustomobject]@{
        Milli = [int]$milli
        Canonical = [string]::Format($Invariant, '{0:000}.{1:000}', $q, $r)
    }
}

function ConvertTo-StateEpoch([string]$Raw, [int]$Width) {
    if ([string]::IsNullOrEmpty($Raw) -or $Raw -notmatch '\A(?:0|[1-9][0-9]{0,11})\z') { return $null }
    $value = 0L
    if (-not [long]::TryParse($Raw, $IntegerStyle, $Invariant, [ref]$value)) { return $null }
    if ($value -lt 0 -or $value -gt 253402300799L) { return $null }
    if ($Width -eq 10 -and $value -gt 9999999999L) { return $null }
    $format = 'D' + [string]$Width
    return [pscustomobject]@{ Value = $value; Padded = $value.ToString($format, $Invariant) }
}

function ConvertTo-StatePayloadEpoch([string]$Raw, [int]$Width) {
    if ([string]::IsNullOrEmpty($Raw)) { return $null }
    if ($Raw.IndexOf('T') -ge 0) {
        $value = ConvertTo-Epoch $Raw
        if ($null -eq $value) { return $null }
        return ConvertTo-StateEpoch ([string]$value) $Width
    }
    return ConvertTo-StateEpoch $Raw $Width
}

function Get-RoundEvenInt64([long]$Numerator, [long]$Denominator) {
    if ($Numerator -lt 0 -or $Denominator -le 0) { return 0L }
    $remainder = 0L
    $quotient = [Math]::DivRem($Numerator, $Denominator, [ref]$remainder)
    $twice = $remainder * 2L
    if ($twice -gt $Denominator -or ($twice -eq $Denominator -and ($quotient % 2L) -eq 1L)) { $quotient++ }
    return $quotient
}

function Format-StateRate([long]$ScaledNumerator, [long]$Denominator) {
    if ($ScaledNumerator -lt 0 -or $Denominator -le 0) { return '0.0000000000' }
    $scaled = Get-RoundEvenInt64 $ScaledNumerator $Denominator
    $fraction = 0L
    $whole = [Math]::DivRem($scaled, 10000000000L, [ref]$fraction)
    return [string]::Format($Invariant, '{0}.{1:0000000000}', $whole, $fraction)
}

function Format-StatePct([int]$Milli) {
    $fraction = 0L
    $whole = [Math]::DivRem([long]$Milli, 1000L, [ref]$fraction)
    return [string]::Format($Invariant, '{0:000}.{1:000}', $whole, $fraction)
}

function Format-BurnPct([int]$Milli) {
    $fraction = 0L
    $whole = [Math]::DivRem([long]$Milli, 1000L, [ref]$fraction)
    return [string]::Format($Invariant, '{0}.{1:000}', $whole, $fraction)
}

function Get-StatePaths([string]$Base) {
    $full = ConvertTo-LocalFullPath $Base ([Environment]::CurrentDirectory)
    if ([string]::IsNullOrEmpty($full)) { return $null }
    $root = $full
    if ($root.EndsWith('.tsv', [StringComparison]::Ordinal)) { $root = $root.Substring(0, $root.Length - 4) }
    $root += '.d'
    return [pscustomobject]@{ Base = $full; Root = $root }
}

function Test-StateRoot([string]$Root) {
    if ([string]::IsNullOrEmpty($Root) -or -not (Test-NoReparseComponents $Root)) { return $false }
    try {
        $attrs = [IO.File]::GetAttributes($Root)
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        return ($attrs -band [IO.FileAttributes]::Directory) -ne 0
    } catch [IO.FileNotFoundException] { return $true }
    catch [IO.DirectoryNotFoundException] { return $true }
    catch { return $false }
}

function Test-StateRegularFile([string]$Path) {
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-NoReparseComponents $Path)) { return $false }
    try {
        $attrs = [IO.File]::GetAttributes($Path)
        return (($attrs -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and ($attrs -band [IO.FileAttributes]::Directory) -eq 0)
    } catch { return $false }
}

function Get-EmptyStateDirectoryStatus([string]$Path) {
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-NoReparseComponents $Path)) { return [pscustomobject]@{ Success=$false; Empty=$false } }
    $enumerator = $null
    try {
        $attrs = [IO.File]::GetAttributes($Path)
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($attrs -band [IO.FileAttributes]::Directory) -eq 0) { return [pscustomobject]@{ Success=$true; Empty=$false } }
        $enumerator = [IO.Directory]::EnumerateFileSystemEntries($Path).GetEnumerator()
        return [pscustomobject]@{ Success=$true; Empty=(-not $enumerator.MoveNext()) }
    } catch { return [pscustomobject]@{ Success=$false; Empty=$false } }
    finally { if ($null -ne $enumerator) { $enumerator.Dispose() } }
}

function Test-EmptyStateDirectory([string]$Path) {
    $status = Get-EmptyStateDirectoryStatus $Path
    return $status.Success -and $status.Empty
}

function Test-StateObjectExists([string]$Path) {
    try { [void][IO.File]::GetAttributes($Path); return $true }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.DirectoryNotFoundException] { return $false }
    catch { return $true }
}

function ConvertFrom-CanonicalStatePct([string]$Raw) {
    if ($Raw -notmatch '\A(?:0[0-9]{2}|100)\.[0-9]{3}\z') { return $null }
    $whole = 0
    $fraction = 0
    if (-not [int]::TryParse($Raw.Substring(0, 3), $IntegerStyle, $Invariant, [ref]$whole)) { return $null }
    if (-not [int]::TryParse($Raw.Substring(4, 3), $IntegerStyle, $Invariant, [ref]$fraction)) { return $null }
    $milli = $whole * 1000 + $fraction
    if ($milli -gt 100000) { return $null }
    return $milli
}

function ConvertFrom-LimitName([string]$Name, [long]$NowValue, [long]$MaxAhead) {
    $match = [regex]::Match($Name, '\A([0-9]{10})_((?:0[0-9]{2}|100)\.[0-9]{3})\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) { return $null }
    $reset = 0L
    if (-not [long]::TryParse($match.Groups[1].Value, $IntegerStyle, $Invariant, [ref]$reset)) { return $null }
    $pct = ConvertFrom-CanonicalStatePct $match.Groups[2].Value
    if ($null -eq $pct) { return $null }
    $plausible = $reset -gt $NowValue -and $reset -le ($NowValue + $MaxAhead)
    return [pscustomobject]@{ Name=$Name; Reset=$reset; Pct=[int]$pct; Plausible=$plausible }
}

function Get-StateDirectorySnapshot([string]$Root, [int]$Cap, [long]$NowValue, [long]$MaxAhead) {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-StateRoot $Root)) { return [pscustomobject]@{ Complete=$false; Raw=0; Entries=@() } }
    if (-not [IO.Directory]::Exists($Root)) { return [pscustomobject]@{ Complete=$true; Raw=0; Entries=@() } }
    $raw = 0
    $enumerator = $null
    try {
        $enumerator = [IO.Directory]::EnumerateFileSystemEntries($Root).GetEnumerator()
        while ($enumerator.MoveNext()) {
            $path = [string]$enumerator.Current
            $raw++
            if ($raw -gt $Cap) { return [pscustomobject]@{ Complete=$false; Raw=$raw; Entries=@() } }
            $full = ConvertTo-LocalFullPath $path $Root
            if ([string]::IsNullOrEmpty($full) -or -not (Test-PathInside $full $Root)) { continue }
            if (-not [IO.Path]::GetDirectoryName($full).Equals($Root, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $name = [IO.Path]::GetFileName($full)
            try { $attrs = [IO.File]::GetAttributes($full) } catch { return [pscustomobject]@{ Complete=$false; Raw=$raw; Entries=@() } }
            if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $parsed = ConvertFrom-LimitName $name $NowValue $MaxAhead
            if ($null -eq $parsed -or ($attrs -band [IO.FileAttributes]::Directory) -eq 0) { continue }
            $emptyStatus = Get-EmptyStateDirectoryStatus $full
            if (-not $emptyStatus.Success) { return [pscustomobject]@{ Complete=$false; Raw=$raw; Entries=@() } }
            if (-not $emptyStatus.Empty) { continue }
            $parsed | Add-Member -NotePropertyName Path -NotePropertyValue $full
            [void]$entries.Add($parsed)
        }
    } catch { return [pscustomobject]@{ Complete=$false; Raw=$raw; Entries=@() } }
    finally { if ($null -ne $enumerator) { $enumerator.Dispose() } }
    return [pscustomobject]@{ Complete=$true; Raw=$raw; Entries=$entries.ToArray() }
}

function ConvertFrom-BurnRecord([string]$Record, [long]$NowValue) {
    $fields = $Record.Split(@("`t"), [StringSplitOptions]::None)
    if ($fields.Length -ne 3) { return $null }
    $sampleValue = ConvertTo-StateEpoch $fields[0] 12
    $pct = ConvertTo-StatePct $fields[1]
    if ($null -eq $pct) {
        $canonical = ConvertFrom-CanonicalStatePct $fields[1]
        if ($null -ne $canonical) { $pct = [pscustomobject]@{ Milli=[int]$canonical } }
    }
    $resetValue = ConvertTo-StateEpoch $fields[2] 12
    if ($null -eq $sampleValue -or $null -eq $pct -or $null -eq $resetValue) { return $null }
    $sample = [long]$sampleValue.Value
    $reset = [long]$resetValue.Value
    $plausible = $sample -le ($NowValue + 300L) -and $reset -ge $sample -and $reset -le ($NowValue + 21600L)
    return [pscustomobject]@{ Reset=$reset; Sample=$sample; Pct=[int]$pct.Milli; Plausible=$plausible }
}

# A killed render dies before its finally block, leaving the trim temporary (or the
# replace backup) behind, and nothing retired those. Sweep on the mutating path
# only, taking only what is unambiguously ours and unambiguously dead: the complete
# name Write-BurnState generates, a regular file, and last written before the store
# it was derived from, since a temporary a live render is still writing is newer
# than the base it is about to replace. Matching the whole shape rather than the
# prefix keeps an unrelated file in a shared directory out of it.
# The name deliberately carries no store identity. Two burn stores configured into
# one directory share this namespace, so "older than my store" alone would let one
# delete the other's live temporary and leave its File.Replace to fail. The age
# floor is what separates them: a render lives well under a second, so nothing a
# live render owns is an hour old, whatever store it belongs to. Encoding the store
# name instead would bound nothing, since a long but legal BURN_FILE basename pushes
# the component past the 255-character NTFS limit and every CreateNew then fails,
# silently stopping the store from ever trimming again.
# Enumeration is lazy and bounded on both counts, so neither the scan nor the
# deletions can stall a render; whatever is left goes on the next one. A directory
# holding thousands of NON-generated .burn.* names could keep the tail out of
# reach, which no store this sweep is meant for looks like.
function Remove-BurnTemporaries([string]$Parent, [string]$Path) {
    try {
        if (-not (Test-StateRegularFile $Path)) { return }
        $baseWrite = [IO.File]::GetLastWriteTimeUtc($Path)
        $ageFloor = [DateTime]::UtcNow.AddHours(-1)
        $swept = 0
        $seen = 0
        foreach ($name in [IO.Directory]::EnumerateFiles($Parent, '.burn.*')) {
            $seen++
            if ($swept -ge 128 -or $seen -gt 4096) { break }
            $leaf = [IO.Path]::GetFileName($name)
            if ($leaf -notmatch '^\.burn\.(tmp|bak)\.[0-9]{1,10}\.[0-9a-fA-F]{32}$') { continue }
            if (-not (Test-StateRegularFile $name)) { continue }
            $written = [IO.File]::GetLastWriteTimeUtc($name)
            if ($written -ge $baseWrite -or $written -ge $ageFloor) { continue }
            try { [IO.File]::Delete($name); $swept++ } catch { }
        }
    } catch { }
}

function Write-BurnState([string]$Path, [object[]]$Rows, [bool]$Mutate) {
    if (-not $Mutate -or [string]::IsNullOrEmpty($Path) -or -not (Test-NoReparseComponents $Path)) { return $false }
    $parent = $null
    try { $parent = [IO.Path]::GetDirectoryName($Path) } catch { return $false }
    if ([string]::IsNullOrEmpty($parent) -or -not (Test-NoReparseComponents $parent)) { return $false }
    try {
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    } catch { return $false }
    if (-not (Test-NoReparseComponents $parent) -or -not [IO.Directory]::Exists($parent)) { return $false }
    if ((Test-StateObjectExists $Path) -and -not (Test-StateRegularFile $Path)) { return $false }

    $builder = New-Object Text.StringBuilder
    foreach ($row in @($Rows)) {
        [void]$builder.Append(([long]$row.Sample).ToString($Invariant))
        [void]$builder.Append("`t")
        [void]$builder.Append((Format-BurnPct ([int]$row.Pct)))
        [void]$builder.Append("`t")
        [void]$builder.Append(([long]$row.Reset).ToString($Invariant))
        [void]$builder.Append("`n")
    }
    $temp = ''
    $backup = ''
    try {
        for ($attempt = 0; $attempt -lt 8; $attempt++) {
            $candidate = [IO.Path]::Combine($parent, '.burn.tmp.' + [string]$PID + '.' + [guid]::NewGuid().ToString('N'))
            if ($candidate.Length -gt 4096) { return $false }
            $stream = $null
            try {
                $stream = New-Object IO.FileStream($candidate, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
                $bytes = $Utf8NoBom.GetBytes($builder.ToString())
                if ($bytes.Length -gt 0) { $stream.Write($bytes, 0, $bytes.Length) }
                $stream.Flush($true)
                $stream.Dispose()
                $stream = $null
                $temp = $candidate
                break
            } catch [IO.IOException] {
                if ($null -ne $stream) { $stream.Dispose() }
            } catch {
                if ($null -ne $stream) { $stream.Dispose() }
                return $false
            }
        }
        if ([string]::IsNullOrEmpty($temp) -or -not (Test-NoReparseComponents $parent)) { return $false }
        if (Test-StateObjectExists $Path) {
            if (-not (Test-StateRegularFile $Path)) { return $false }
            for ($attempt = 0; $attempt -lt 8; $attempt++) {
                $backup = [IO.Path]::Combine($parent, '.burn.bak.' + [string]$PID + '.' + [guid]::NewGuid().ToString('N'))
                if ($backup.Length -gt 4096) { $backup = ''; return $false }
                if (-not (Test-StateObjectExists $backup)) { break }
                $backup = ''
            }
            if ([string]::IsNullOrEmpty($backup)) { return $false }
            [IO.File]::Replace($temp, $Path, $backup)
            if (Test-StateRegularFile $backup) { [IO.File]::Delete($backup); $backup = '' }
            elseif (-not (Test-StateObjectExists $backup)) { $backup = '' }
        } else {
            [IO.File]::Move($temp, $Path)
        }
        $temp = ''
        return $true
    } catch { return $false }
    finally {
        foreach ($leftover in @($temp, $backup)) {
            if (-not [string]::IsNullOrEmpty($leftover)) {
                try { if (Test-StateRegularFile $leftover) { [IO.File]::Delete($leftover) } } catch { }
            }
        }
    }
}

function Read-BurnState([string]$Path, [long]$NowValue, [int]$Trim, [bool]$Mutate) {
    if (-not [IO.File]::Exists($Path)) {
        if (Test-StateObjectExists $Path) { return [pscustomobject]@{ Complete=$false; Exists=$false; Raw=0; Rows=@() } }
        if (Test-NoReparseComponents $Path) { return [pscustomobject]@{ Complete=$true; Exists=$false; Raw=0; Rows=@() } }
        return [pscustomobject]@{ Complete=$false; Exists=$false; Raw=0; Rows=@() }
    }
    if (-not (Test-StateRegularFile $Path)) { return [pscustomobject]@{ Complete=$false; Exists=$true; Raw=0; Rows=@() } }
    # Sweep here, not in Write-BurnState: a rewrite happens only once the store is
    # over BURN_TRIM or needs healing, and orphans have to be retired on every
    # mutating render, which is where the Bash runtime sweeps them.
    if ($Mutate) {
        $sweepParent = $null
        try { $sweepParent = [IO.Path]::GetDirectoryName($Path) } catch { $sweepParent = $null }
        if (-not [string]::IsNullOrEmpty($sweepParent)) { Remove-BurnTemporaries $sweepParent $Path }
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $byKey = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $physical = 0
    $heal = $false
    $lastByte = -1
    $stream = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share, 4096, [IO.FileOptions]::SequentialScan)
        $length = [long]$stream.Length
        if ($length -gt 1048576L) { return [pscustomobject]@{ Complete=$false; Exists=$true; Raw=0; Rows=@() } }
        $buffer = New-Object byte[] 4096
        $builder = New-Object Text.StringBuilder
        $remaining = $length
        $recordLength = 0
        $rowAscii = $true
        while ($remaining -gt 0) {
            $want = [int][Math]::Min([long]$buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $want)
            if ($read -le 0) { return [pscustomobject]@{ Complete=$false; Exists=$true; Raw=$physical; Rows=@() } }
            $remaining -= $read
            for ($i=0; $i -lt $read; $i++) {
                $byte = [int]$buffer[$i]
                $lastByte = $byte
                if ($byte -eq 10) {
                    $physical++
                    if ($physical -gt 4096) { return [pscustomobject]@{ Complete=$false; Exists=$true; Raw=$physical; Rows=@() } }
                    if ($rowAscii) {
                        $row = ConvertFrom-BurnRecord $builder.ToString() $NowValue
                        if ($null -ne $row) {
                            if (-not $row.Plausible) { $heal = $true }
                            else {
                                $key = ([string]$row.Reset) + '_' + ([string]$row.Sample)
                                if ($byKey.ContainsKey($key)) {
                                    $old = $byKey[$key]
                                    if ($row.Pct -gt $old.Pct) { $old.Pct = [int]$row.Pct }
                                } else {
                                    $byKey[$key] = $row
                                    [void]$rows.Add($row)
                                }
                            }
                        }
                    }
                    [void]$builder.Clear(); $recordLength=0; $rowAscii=$true
                    continue
                }
                $recordLength++
                if ($recordLength -gt 4096) { return [pscustomobject]@{ Complete=$false; Exists=$true; Raw=$physical; Rows=@() } }
                if ($byte -eq 9 -or $byte -eq 46 -or ($byte -ge 48 -and $byte -le 57)) { [void]$builder.Append([char]$byte) }
                else { $rowAscii=$false }
            }
        }
        if ($length -gt 0 -and $lastByte -ne 10 -and $length -ge 1048576L) {
            return [pscustomobject]@{ Complete=$false; Exists=$true; Raw=$physical; Rows=@() }
        }
        if ($recordLength -gt 0) {
            $physical++
            if ($physical -gt 4096) { return [pscustomobject]@{ Complete=$false; Exists=$true; Raw=$physical; Rows=@() } }
            if ($rowAscii) {
                $row = ConvertFrom-BurnRecord $builder.ToString() $NowValue
                if ($null -ne $row) {
                    if (-not $row.Plausible) { $heal = $true }
                    else {
                        $key = ([string]$row.Reset) + '_' + ([string]$row.Sample)
                        if ($byKey.ContainsKey($key)) {
                            $old = $byKey[$key]
                            if ($row.Pct -gt $old.Pct) { $old.Pct = [int]$row.Pct }
                        } else {
                            $byKey[$key] = $row
                            [void]$rows.Add($row)
                        }
                    }
                }
            }
        }
    } catch { return [pscustomobject]@{ Complete=$false; Exists=$true; Raw=$physical; Rows=@() } }
    finally { if ($null -ne $stream) { $stream.Dispose() } }

    $finalRows = $rows.ToArray()
    if ($Mutate -and ($physical -gt $Trim -or $heal)) {
        $retained = New-Object 'System.Collections.Generic.List[object]'
        $start = [Math]::Max(0, $finalRows.Length - $Trim)
        for ($i=$start; $i -lt $finalRows.Length; $i++) { [void]$retained.Add($finalRows[$i]) }
        [void](Write-BurnState $Path $retained.ToArray() $true)
    }
    return [pscustomobject]@{ Complete=$true; Exists=$true; Raw=$physical; Rows=$finalRows }
}

function Append-BurnState([string]$Path, $Current, [bool]$Mutate) {
    if (-not $Mutate -or $null -eq $Current -or -not $Current.Valid -or [string]::IsNullOrEmpty($Path)) { return $false }
    $parent = $null
    try { $parent = [IO.Path]::GetDirectoryName($Path) } catch { return $false }
    if ([string]::IsNullOrEmpty($parent) -or -not (Test-NoReparseComponents $parent)) { return $false }
    try {
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    } catch { return $false }
    if (-not (Test-NoReparseComponents $parent) -or -not [IO.Directory]::Exists($parent)) { return $false }
    if ((Test-StateObjectExists $Path) -and -not (Test-StateRegularFile $Path)) { return $false }
    if (-not (Test-NoReparseComponents $Path)) { return $false }
    $record = ([long]$Current.Sample).ToString($Invariant) + "`t" + (Format-BurnPct ([int]$Current.Pct)) + "`t" + ([long]$Current.Reset).ToString($Invariant) + "`n"
    # [IO.File]::AppendAllText opens exclusively for writing and gives up on the
    # first sharing violation, so a second session appending in the same instant
    # loses its sample: measured at 16 concurrent renderers, 5 of 320 rows lost
    # against 0 for the Bash runtime. Widening to FileShare.ReadWrite is worse,
    # not better -- .NET's FileMode.Append seeks to the end once at open rather
    # than per write, so simultaneous writers share an offset and overwrite each
    # other; that measured 62 of 320 lost. The exclusive open is what keeps whole
    # rows intact, and what was actually missing is the retry: a writer that finds
    # the handle held waits and takes its turn instead of dropping the row. The
    # loop only runs under contention.
    $bytes = $Utf8NoBom.GetBytes($record)
    for ($attempt = 0; $attempt -lt 64; $attempt++) {
        $stream = $null
        try {
            $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            return $true
        } catch [IO.IOException] {
            [Threading.Thread]::Sleep(1)
        } catch {
            return $false
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    return $false
}

function Sort-StateEntries([object[]]$Entries) {
    $list = New-Object 'System.Collections.Generic.List[object]'
    $list.AddRange($Entries)
    $comparison = [System.Comparison[object]]{
        param($left, $right)
        return [string]::CompareOrdinal([string]$left.Name, [string]$right.Name)
    }
    $list.Sort($comparison)
    return ,($list.ToArray())
}

function Get-LimitRetention([object[]]$Entries) {
    $sorted = Sort-StateEntries $Entries
    $winner = $null
    foreach ($entry in $sorted) { if ($entry.Plausible) { $winner = $entry } }
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $sorted) { if ($null -eq $winner -or -not [object]::ReferenceEquals($entry, $winner)) { [void]$candidates.Add($entry) } }
    return [pscustomobject]@{ Candidates=$candidates.ToArray(); Winner=$winner }
}

function Test-LimitDeleteCandidate([string]$Root, $Entry, [long]$MaxAhead) {
    if ($null -eq $Entry -or -not $Entry.Path.Equals([IO.Path]::Combine($Root, $Entry.Name), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not (Test-StateRoot $Root) -or -not [IO.Directory]::Exists($Root)) { return $false }
    if ($null -eq (ConvertFrom-LimitName $Entry.Name $Now $MaxAhead)) { return $false }
    return Test-EmptyStateDirectory $Entry.Path
}

function Remove-StateCandidates([string]$Root, [object[]]$Candidates, [long]$MaxAhead, [bool]$Mutate) {
    if (-not $Mutate) { return [pscustomobject]@{ Resolved=0; Clean=($Candidates.Count -eq 0) } }
    $limit = [Math]::Min(128, $Candidates.Count)
    $resolved = 0
    for ($i=0; $i -lt $limit; $i++) {
        $entry = $Candidates[$i]
        if (-not (Test-StateObjectExists $entry.Path)) { $resolved++; continue }
        if (-not (Test-LimitDeleteCandidate $Root $entry $MaxAhead)) { continue }
        try {
            [IO.Directory]::Delete($entry.Path, $false)
        } catch { }
        if (-not (Test-StateObjectExists $entry.Path)) { $resolved++ }
    }
    return [pscustomobject]@{ Resolved=$resolved; Clean=($resolved -eq $Candidates.Count) }
}

# Valid stays strict: it gates sampling, publication, and the burn binding. Elapsed
# describes the one other state a renderer may show, a window whose pct and reset
# both passed validation and whose reset has since passed. A missing or malformed
# reset produces neither, so no renderer can claim an elapsed window that was never
# observed, and a reset beyond the window ceiling stays rejected as in #32.
# Elapsed is for a window that JUST closed, so the same ceiling bounds it in the
# past: Claude Code keeps replaying the last snapshot an idle session received, and
# sessions were observed still reporting a window that had closed 27 and 75 hours
# earlier. Past the bound the renderer falls through to the store, which only ever
# holds windows that are still open.
function Get-CurrentLimit([string]$RawPct, [string]$RawReset, [long]$NowValue, [long]$MaxAhead) {
    $pct = ConvertTo-StatePct $RawPct
    $reset = ConvertTo-StatePayloadEpoch $RawReset 10
    $none = [pscustomobject]@{ Valid=$false; Pct=0; Reset=0L; Elapsed=$false; ElapsedPct=0; ElapsedReset=0L }
    if ($null -eq $pct -or $null -eq $reset) { return $none }
    $milli = [int]$pct.Milli
    $value = [long]$reset.Value
    if ($value -gt $NowValue -and $value -le ($NowValue + $MaxAhead)) {
        return [pscustomobject]@{ Valid=$true; Pct=$milli; Reset=$value; Elapsed=$false; ElapsedPct=0; ElapsedReset=0L }
    }
    if ($value -gt 0L -and $value -le $NowValue -and ($NowValue - $value) -le $MaxAhead) {
        return [pscustomobject]@{ Valid=$false; Pct=0; Reset=0L; Elapsed=$true; ElapsedPct=$milli; ElapsedReset=$value }
    }
    return $none
}

# This session's own reading wins its own window; the store wins only when it holds
# a newer one. Preferring the stored maximum for the same reset assumed usage inside
# a window only rises, which breaks whenever the percentage legitimately drops while
# resets_at stays put (upstream limit reset, plan upgrade, server-side adjustment):
# the recorded maximum then became unbeatable for the rest of the window. Nothing in
# the payload timestamps an observation, so a stale high reading cannot be aged out.
function Select-LimitResult($Snapshot, $Retention, $Current) {
    $valid = $false
    $reset = 0L
    $pct = 0
    if ($Snapshot.Complete -and $null -ne $Retention.Winner) { $valid=$true; $reset=[long]$Retention.Winner.Reset; $pct=[int]$Retention.Winner.Pct }
    if ($Current.Valid -and (-not $valid -or $Current.Reset -ge $reset)) {
        $valid=$true; $reset=[long]$Current.Reset; $pct=[int]$Current.Pct
    }
    return [pscustomobject]@{ Valid=$valid; Reset=$reset; Pct=$pct }
}

function Publish-LimitState([string]$Root, $Current, $Snapshot, $Gc, [long]$MaxAhead, [bool]$Mutate) {
    if (-not $Mutate -or -not $Snapshot.Complete -or -not $Gc.Clean -or -not $Current.Valid) { return $false }
    if (($Snapshot.Raw - $Gc.Resolved) -ge 384) { return $false }
    if (-not (Test-StateRoot $Root)) { return $false }
    $name = $Current.Reset.ToString('D10', $Invariant) + '_' + (Format-StatePct $Current.Pct)
    $path = [IO.Path]::Combine($Root, $name)
    if (-not (Test-NoReparseComponents $path)) { return $false }
    try { [void][IO.Directory]::CreateDirectory($path) } catch { return $false }
    return Test-LimitDeleteCandidate $Root ([pscustomobject]@{ Name=$name; Path=$path }) $MaxAhead
}

function Get-Burn5Estimate($Snapshot, $Current, [long]$NowValue, [int]$Window) {
    $warming = [pscustomobject]@{ State='warming'; Eta='inf'; Rate='0.0000000000'; Ttr=0L }
    if (-not $Snapshot.Complete) { return $warming }
    $observations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $Snapshot.Rows) { [void]$observations.Add($row) }
    if ($Current.Valid) { [void]$observations.Add($Current) }
    if ($observations.Count -eq 0) { return $warming }
    $maxReset = 0L
    foreach ($observation in $observations) { if ([long]$observation.Reset -gt $maxReset) { $maxReset = [long]$observation.Reset } }
    if ($maxReset -le 0) { return $warming }
    $dedup = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $perSecond = New-Object 'System.Collections.Generic.Dictionary[long,int]'
    foreach ($observation in $observations) {
        if ([long]$observation.Reset -ne $maxReset) { continue }
        $key = ([string]$observation.Reset) + '_' + ([string]$observation.Sample) + '_' + ([string]$observation.Pct)
        if (-not $dedup.Add($key)) { continue }
        $sample = [long]$observation.Sample
        $pct = [int]$observation.Pct
        if (-not $perSecond.ContainsKey($sample) -or $pct -gt $perSecond[$sample]) { $perSecond[$sample] = $pct }
    }
    if ($perSecond.Count -eq 0) { return $warming }
    $samples = [long[]]@($perSecond.Keys)
    [Array]::Sort($samples)
    $ttr = $maxReset - $NowValue
    if ($ttr -lt 0) { $ttr = 0 }
    $cutoff = $NowValue - $Window
    $unusedRemainder = 0L
    $minSpan = [Math]::DivRem([long]$Window, 10L, [ref]$unusedRemainder)
    $firstTime = 0L; $firstPct = -1; $lastTime = 0L; $lastPct = -1; $crossings = 0; $anyCrossing = $false
    for ($i=1; $i -lt $samples.Length; $i++) {
        $aRem = 0L; $bRem = 0L
        $a = [Math]::DivRem([long]$perSecond[$samples[$i-1]], 1000L, [ref]$aRem)
        $b = [Math]::DivRem([long]$perSecond[$samples[$i]], 1000L, [ref]$bRem)
        if ($b -le $a) { continue }
        $anyCrossing = $true
        $crossTime = $samples[$i]
        if ($crossTime -ge $cutoff -and $crossTime -le $NowValue) {
            if ($firstPct -lt 0) { $firstTime=$crossTime; $firstPct=[int]$b }
            $lastTime=$crossTime; $lastPct=[int]$b; $crossings++
        }
    }
    if ($crossings -ge 2 -and $lastTime -gt $firstTime -and $lastPct -gt $firstPct -and ($lastTime - $firstTime) -ge $minSpan) {
        $span = $lastTime - $firstTime
        $delta = [long]($lastPct - $firstPct)
        $latest = [long]$perSecond[$samples[$samples.Length - 1]]
        $eta = Get-RoundEvenInt64 ((100000L - $latest) * $span) ($delta * 1000L)
        $rate = Format-StateRate ($delta * 10000000000L) $span
        return [pscustomobject]@{ State='active'; Eta=$eta; Rate=$rate; Ttr=$ttr }
    }
    if ($anyCrossing -and $crossings -eq 0) { return [pscustomobject]@{ State='idle'; Eta='inf'; Rate='0.0000000000'; Ttr=$ttr } }
    return [pscustomobject]@{ State='warming'; Eta='inf'; Rate='0.0000000000'; Ttr=$ttr }
}

function Get-Burn7Estimate($Limit, [long]$NowValue) {
    if (-not $Limit.Valid) { return [pscustomobject]@{ Eta='inf'; Rate='0.0000000000'; Ttr=0L } }
    $ttr = [long]$Limit.Reset - $NowValue
    if ($ttr -lt 0) { $ttr = 0 }
    $elapsed = $NowValue - ([long]$Limit.Reset - 604800L)
    if ($Limit.Pct -le 0 -or $elapsed -lt 1 -or $elapsed -gt 691200L) { return [pscustomobject]@{ Eta='inf'; Rate='0.0000000000'; Ttr=$ttr } }
    $rate = Format-StateRate ([long]$Limit.Pct * 10000000L) $elapsed
    $eta = Get-RoundEvenInt64 ((100000L - [long]$Limit.Pct) * $elapsed) ([long]$Limit.Pct)
    return [pscustomobject]@{ Eta=$eta; Rate=$rate; Ttr=$ttr }
}

function Get-BurnBinding($Five, $Seven) {
    $fiveFinite = [string]$Five.Eta -ne 'inf'
    $sevenFinite = [string]$Seven.Eta -ne 'inf'
    if ($fiveFinite -and (-not $sevenFinite -or [long]$Five.Eta -le [long]$Seven.Eta)) {
        return [pscustomobject]@{ State='active'; Label='5h'; Eta=[long]$Five.Eta; Rate=$Five.Rate; Ttr=[long]$Five.Ttr }
    }
    if ($sevenFinite) { return [pscustomobject]@{ State='active'; Label='7d'; Eta=[long]$Seven.Eta; Rate=$Seven.Rate; Ttr=[long]$Seven.Ttr } }
    $state = 'warming'
    if ($Five.State -eq 'idle') { $state = 'idle' }
    return [pscustomobject]@{ State=$state; Label=''; Eta='inf'; Rate='0.0000000000'; Ttr=0L }
}

function Get-CorallineState([bool]$BurnGate, [bool]$Limit5Gate, [bool]$Limit7Gate) {
    $mutate = [string]$env:CORALLINE_NO_SAMPLE -ne '1'
    $window = Get-BoundedInt $Cfg.CORALLINE_BURN_WINDOW 600 60 86400
    $trim = Get-BoundedInt $Cfg.BURN_TRIM 1500 1 3000
    $current5 = Get-CurrentLimit $fhPct $fhRst $Now 21600L
    $current7 = Get-CurrentLimit $wdPct $wdRst $Now 691200L
    $currentBurn = [pscustomobject]@{ Valid=$false; Reset=0L; Sample=$Now; Pct=0 }
    if ($current5.Valid -and $current5.Reset -ge $Now) { $currentBurn = [pscustomobject]@{ Valid=$true; Reset=[long]$current5.Reset; Sample=$Now; Pct=[int]$current5.Pct } }

    $emptySnapshot = [pscustomobject]@{ Complete=$false; Exists=$false; Raw=0; Entries=@(); Rows=@() }
    $burnSnapshot=$emptySnapshot; $limit5Snapshot=$emptySnapshot; $limit7Snapshot=$emptySnapshot
    $burnPaths=$null; $limit5Paths=$null; $limit7Paths=$null
    if ($BurnGate) { $burnPaths = Get-StatePaths $Cfg.BURN_FILE }
    if ($Limit5Gate) { $limit5Paths = Get-StatePaths $Cfg.RL5H_FILE }
    if ($Limit7Gate) { $limit7Paths = Get-StatePaths $Cfg.RL7D_FILE }
    # Bash compares all six canonical paths pairwise in state_paths_validate, not
    # just the three roots, and it does so for every configured store regardless
    # of which segments are enabled. Both parts matter here.
    #
    # Roots alone miss a base that aliases another store's root: BURN_FILE=
    # ...\limit5.d together with RL5H_FILE=...\limit5.tsv gives burn.Base equal to
    # limit5.Root, because a root is a base with .tsv replaced by .d. That was
    # harmless while the burn store was a directory and its base was never
    # written; the burn base is now an appended file, so the append would create
    # limit5.d as a regular file and block the limit store permanently.
    #
    # Gate-filtered paths miss the same alias whenever the other store is dormant,
    # which is the default: with VL_LIMIT_SYNC=0 the limit paths are never derived,
    # so their roots never enter the namespace and the append lands anyway. The
    # damage outlives the setting -- enabling synchronisation later finds a
    # regular file where the store belongs. So the namespace is built from the
    # configuration, not from this render's gates.
    #
    # Measured on Windows for both shapes, sync enabled and sync disabled:
    # statusline.sh created nothing at all, statusline.ps1 created the file.
    $collision = $false
    $namespace = New-Object 'System.Collections.Generic.List[string]'
    foreach ($configured in @($Cfg.BURN_FILE, $Cfg.RL5H_FILE, $Cfg.RL7D_FILE)) {
        if ([string]::IsNullOrEmpty([string]$configured)) { continue }
        $candidate = Get-StatePaths $configured
        if ($null -ne $candidate) {
            [void]$namespace.Add([string]$candidate.Base)
            [void]$namespace.Add([string]$candidate.Root)
        }
    }
    for ($i=0; $i -lt $namespace.Count; $i++) {
        for ($j=$i+1; $j -lt $namespace.Count; $j++) {
            if ($namespace[$i].Equals($namespace[$j], [StringComparison]::OrdinalIgnoreCase)) { $collision = $true }
        }
    }
    # A state path must not alias a file the renderer reads or writes for another
    # purpose. The burn base is now appended to, so any such alias means a TSV
    # record lands in that file: the render still succeeds, and the damage shows
    # up on the next one, in a file the user has to repair by hand.
    #
    # This is the complete set for the main render path, enumerated rather than
    # discovered one report at a time. The renderer reads the config, every file
    # the config includes (themes arrive this way), and its own script; it writes
    # the float target. Test-FloatCollision already protects the float writer
    # against the state paths, so this is the same relation in the other
    # direction, and both must hold because the state append runs first.
    #
    # The transcript is deliberately absent: it is used only to derive a subagent
    # sidecar path under --subagent, and that mode performs no state mutation.
    #
    # Protected paths are compared against state paths only, never against each
    # other, so a repeated include cannot manufacture a collision.
    if (-not $collision) {
        $protected = New-Object 'System.Collections.Generic.List[string]'
        $runtimePath = ''
        try { $runtimePath = [IO.Path]::GetFullPath($ScriptPath) } catch { }
        $floatTarget = ''
        if (-not [string]::IsNullOrEmpty([string]$Cfg.VL_FLOAT_FILE) -and ([string]$Cfg.VL_FLOAT_FILE).Length -le 4096) {
            $floatTarget = ConvertTo-LocalFullPath ([string]$Cfg.VL_FLOAT_FILE) ([Environment]::CurrentDirectory)
        }
        foreach ($path in @($ConfigPath, $runtimePath, $floatTarget)) {
            if (-not [string]::IsNullOrEmpty([string]$path)) { [void]$protected.Add([string]$path) }
        }
        foreach ($path in $ConfigVisitedPaths) {
            if (-not [string]::IsNullOrEmpty([string]$path)) { [void]$protected.Add([string]$path) }
        }
        foreach ($statePath in $namespace) {
            foreach ($guard in $protected) {
                if ($statePath.Equals($guard, [StringComparison]::OrdinalIgnoreCase)) { $collision = $true }
            }
        }
    }
    if (-not $collision) {
        if ($BurnGate -and $null -ne $burnPaths) {
            [void](Append-BurnState $burnPaths.Base $currentBurn $mutate)
            $burnSnapshot = Read-BurnState $burnPaths.Base $Now $trim $mutate
        }
        if ($Limit5Gate -and $null -ne $limit5Paths) { $limit5Snapshot = Get-StateDirectorySnapshot $limit5Paths.Root 512 $Now 21600L }
        if ($Limit7Gate -and $null -ne $limit7Paths) { $limit7Snapshot = Get-StateDirectorySnapshot $limit7Paths.Root 512 $Now 691200L }
    }

    $limit5Retention = [pscustomobject]@{ Candidates=@(); Winner=$null }
    $limit7Retention = [pscustomobject]@{ Candidates=@(); Winner=$null }
    if ($limit5Snapshot.Complete) { $limit5Retention = Get-LimitRetention $limit5Snapshot.Entries }
    if ($limit7Snapshot.Complete) { $limit7Retention = Get-LimitRetention $limit7Snapshot.Entries }

    $limit5Gc = [pscustomobject]@{ Resolved=0; Clean=$false }
    $limit7Gc = [pscustomobject]@{ Resolved=0; Clean=$false }
    if ($limit5Snapshot.Complete) { $limit5Gc = Remove-StateCandidates $limit5Paths.Root $limit5Retention.Candidates 21600L $mutate }
    if ($limit7Snapshot.Complete) { $limit7Gc = Remove-StateCandidates $limit7Paths.Root $limit7Retention.Candidates 691200L $mutate }

    $limit5 = Select-LimitResult $limit5Snapshot $limit5Retention $current5
    $limit7 = Select-LimitResult $limit7Snapshot $limit7Retention $current7
    if ($Limit5Gate -and $limit5Snapshot.Complete) { [void](Publish-LimitState $limit5Paths.Root $current5 $limit5Snapshot $limit5Gc 21600L $mutate) }
    if ($Limit7Gate -and $limit7Snapshot.Complete) { [void](Publish-LimitState $limit7Paths.Root $current7 $limit7Snapshot $limit7Gc 691200L $mutate) }

    $five = Get-Burn5Estimate $burnSnapshot $currentBurn $Now $window
    # The 5h projection needs the same rebinding the 7d one gets: whenever the synced
    # state is what the gauge draws, the ETA has to come from that same window. Two
    # ways they diverge. With no reading of our own the history can still be on the
    # window that just closed, since an expired reset stays plausible to the reader
    # and its Ttr clamps to zero. With a valid reading of our own that a NEWER stored
    # window beats, the history holds only our older window, and the session that
    # published the newer one need not have burn enabled to contribute samples for
    # it. Both put an active ETA for one window beside a gauge for another, so gate
    # on the stored state alone, not on whether we have a reading. The estimate
    # reports its window as Now + Ttr; warming when it does not match is honest, no
    # samples for that window have been observed yet.
    if ($Cfg.VL_LIMIT_SYNC -eq '1' -and $limit5.Valid -and
        ($Now + [long]$five.Ttr) -ne [long]$limit5.Reset) {
        $five = [pscustomobject]@{ State='warming'; Eta='inf'; Rate='0.0000000000'; Ttr=0L }
    }
    # The ownership rule covers the projection as well, and it has to be the SAME
    # rule: burn can bind to the 7d window, so any source Add-Limit7Segment is
    # willing to display must also be the source the ETA is projected from, or the
    # bar and the gauge report different windows in one render.
    if ($Cfg.VL_LIMIT_SYNC -eq '1' -and $limit7.Valid) { $seven = Get-Burn7Estimate $limit7 $Now }
    else { $seven = Get-Burn7Estimate $current7 $Now }
    $burn = Get-BurnBinding $five $seven
    # Same sources the gauges accept: once a synced store can render 5h/7d for a
    # session that has reported nothing itself, hiding only the projection would
    # leave a gap between two segments that are describing the same windows.
    $burn | Add-Member -NotePropertyName Reported -NotePropertyValue ($current5.Valid -or $current7.Valid -or $limit5.Valid -or $limit7.Valid)
    return [pscustomobject]@{
        Burn=$burn; Five=$five; Seven=$seven; Limit5=$limit5; Limit7=$limit7
        Current5=$current5; Current7=$current7; BurnSnapshotComplete=$burnSnapshot.Complete
        Limit5SnapshotComplete=$limit5Snapshot.Complete; Limit7SnapshotComplete=$limit7Snapshot.Complete
    }
}

function Format-Countdown([string]$ResetsAt) {
    $ep = ConvertTo-Epoch $ResetsAt
    if ($null -eq $ep) { return '' }
    $diff = [long]$ep - $Now
    if ($diff -le 0) { return 'now' }
    $d = [math]::Floor($diff / 86400)
    $h = [math]::Floor(($diff % 86400) / 3600)
    $m = [math]::Floor(($diff % 3600) / 60)
    if ($d -gt 0) { return ('{0}d{1:00}h' -f $d, $h) }
    if ($h -gt 0) { return ('{0}h{1:00}m' -f $h, $m) }
    return "${m}m"
}

function Format-Duration([double]$Ms, [bool]$IncludeSeconds) {
    $s = [long][math]::Floor($Ms / 1000)
    $h = [math]::Floor($s / 3600)
    $m = [math]::Floor(($s % 3600) / 60)
    $sec = $s % 60
    if ($IncludeSeconds) {
        if ($h -gt 0) { return ('{0}h{1:00}m{2:00}s' -f $h, $m, $sec) }
        if ($m -gt 0) { return ('{0}m{1:00}s' -f $m, $sec) }
        return "${s}s"
    }
    if ($h -gt 0) { return ('{0}h{1:00}m' -f $h, $m) }
    if ($m -gt 0) { return "${m}m" }
    return "${s}s"
}

function Get-ClockText {
    $now = Get-Date
    if ($Cfg.VL_CLOCK -ceq '24h') {
        if ($Cfg.VL_CLOCK_SECONDS -eq '1') { return $now.ToString('HH:mm:ss', $Invariant) }
        return $now.ToString('HH:mm', $Invariant)
    }
    $format = 'hh:mm tt'
    if ($Cfg.VL_CLOCK_SECONDS -eq '1') { $format = 'hh:mm:ss tt' }
    $text = $now.ToString($format, $Invariant)
    if ($text.EndsWith('AM', [System.StringComparison]::Ordinal)) { return $text.Substring(0, $text.Length - 2) + 'am' }
    if ($text.EndsWith('PM', [System.StringComparison]::Ordinal)) { return $text.Substring(0, $text.Length - 2) + 'pm' }
    return $text
}

function Get-JsonMember($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    try {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return ,$property.Value
    } catch { return $null }
}

function Get-JsonPath($Object, [string[]]$Names) {
    $value = $Object
    foreach ($name in $Names) {
        $value = Get-JsonMember $value $name
        if ($null -eq $value) { return $null }
    }
    return $value
}

function To-InvariantString($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return [string]$Value }
    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }
    if ($Value -is [System.IFormattable] -and -not ($Value -is [System.Array])) {
        return $Value.ToString($null, $Invariant)
    }
    return ''
}

$JsonParsed = $false
try {
    if ($rawInput -cnotmatch '\A[ \t\r\n]*\{') { throw 'non-object JSON root' }
    $J = $rawInput | ConvertFrom-Json -ErrorAction Stop
    $JsonParsed = ($J -is [pscustomobject] -or $J -is [System.Collections.IDictionary])
    if (-not $JsonParsed) { $J = $null }
} catch { $J = $null }

$cwd = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('workspace', 'current_dir')))
if ([string]::IsNullOrEmpty($cwd)) { $cwd = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('cwd'))) }
$model = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('model', 'display_name')))
$ctxParent = Get-JsonMember $J 'context_window'
$ctxNode = $null
$ctxEmpty = $false
if ($null -eq $ctxParent) {
    $ctxPct = ''
    $ctxEmpty = $true
} elseif ($ctxParent -is [pscustomobject] -or $ctxParent -is [System.Collections.IDictionary]) {
    $ctxNode = Get-JsonMember $ctxParent 'used_percentage'
    if ($null -eq $ctxNode) {
        $ctxPct = ''
        $ctxEmpty = $true
    } elseif ($ctxNode -is [string]) {
        $ctxRaw = [string]$ctxNode
        $ctxPct = Remove-ControlChars $ctxRaw
        $ctxEmpty = $ctxRaw.Length -eq 0
    } elseif ($ctxNode -is [bool] -or $ctxNode -is [System.Array] -or $ctxNode -is [System.Collections.IDictionary] -or $ctxNode -is [pscustomobject]) {
        $ctxPct = ''
    } else {
        $ctxPct = Remove-ControlChars (To-InvariantString $ctxNode)
    }
} else {
    $ctxPct = ''
}
$tokIn = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('context_window', 'total_input_tokens')))
$tokOut = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('context_window', 'total_output_tokens')))
$tokCr = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('context_window', 'current_usage', 'cache_read_input_tokens')))
$tokCw = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('context_window', 'current_usage', 'cache_creation_input_tokens')))
$fhPct = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('rate_limits', 'five_hour', 'used_percentage')))
$fhRst = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('rate_limits', 'five_hour', 'resets_at')))
$wdPct = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('rate_limits', 'seven_day', 'used_percentage')))
$wdRst = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('rate_limits', 'seven_day', 'resets_at')))
# prompt_cache is absent entirely until the session's first request, and either
# field can be null after that. Both are accepted only as JSON numbers, mirroring
# the Bash renderer's `type == "number"` guard, so a string or an object leaves the
# segment suppressed rather than rendering a bogus gauge. hit_ratio arrives as a
# 0..1 ratio and is scaled here, the way the Bash side scales it inside jq.
$cacheHit = ''
$cacheExp = ''
$cacheParent = Get-JsonMember $J 'prompt_cache'
if ($cacheParent -is [pscustomobject] -or $cacheParent -is [System.Collections.IDictionary]) {
    $hitNode = Get-JsonMember $cacheParent 'hit_ratio'
    if ($hitNode -is [double] -or $hitNode -is [decimal] -or $hitNode -is [long] -or $hitNode -is [int]) {
        $cacheHit = To-InvariantString ([double]$hitNode * 100)
    }
    $expNode = Get-JsonMember $cacheParent 'expires_at'
    if ($expNode -is [double] -or $expNode -is [decimal] -or $expNode -is [long] -or $expNode -is [int]) {
        $cacheExp = To-InvariantString $expNode
    }
}
$costParent = Get-JsonMember $J 'cost'
$costNode = $null
$costKind = 'missing'
$costRaw = ''
$cost = ''
if ($null -eq $costParent) {
    $costKind = 'missing'
} elseif ($costParent -is [pscustomobject] -or $costParent -is [System.Collections.IDictionary]) {
    $costNode = Get-JsonMember $costParent 'total_cost_usd'
    if ($null -eq $costNode) {
        $costKind = 'missing'
    } elseif ($costNode -is [string]) {
        $costRaw = [string]$costNode
        $cost = Remove-ControlChars $costRaw
        if ($costRaw.Length -gt 0) { $costKind = 'scalar' }
    } elseif ($costNode -is [bool] -or $costNode -is [System.Array] -or $costNode -is [System.Collections.IDictionary] -or $costNode -is [pscustomobject]) {
        $costKind = 'invalid'
    } elseif ($costNode -is [System.IFormattable]) {
        $costKind = 'scalar'
        $costRaw = To-InvariantString $costNode
        $cost = $costRaw
    } else {
        $costKind = 'invalid'
    }
} else {
    $costKind = 'invalid'
}
$linesAdd = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('cost', 'total_lines_added')))
$linesDel = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('cost', 'total_lines_removed')))
$outStyle = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('output_style', 'name')))
$durMs = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('cost', 'total_duration_ms')))
$effort = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('effort', 'level')))

function ConvertTo-ProbePath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    if ($Path.Length -gt 4096 -or $Path -match '[\u0000-\u001f\u007f-\u009f]') { return '' }
    $p = $Path.Replace('/', '\')
    if ($p.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or $p.StartsWith('\\.\', [System.StringComparison]::Ordinal)) { return '' }
    if (-not $p.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        $local = ConvertTo-LocalFullPath $Path ([Environment]::CurrentDirectory)
        if ($null -eq $local) { return '' }
        return $local
    }

    # Workspace probes are read-only and may follow a normal UNC path. Config,
    # include, float, burn, and rate-limit paths keep using the stricter local
    # validator above and therefore still reject every UNC form.
    $parts = $p.Substring(2).Split(@('\'), [System.StringSplitOptions]::None)
    if ($parts.Length -lt 2 -or [string]::IsNullOrEmpty($parts[0]) -or [string]::IsNullOrEmpty($parts[1])) { return '' }
    for ($i = 0; $i -lt $parts.Length; $i++) {
        $component = $parts[$i]
        if ([string]::IsNullOrEmpty($component)) { continue }
        if (($i -lt 2) -and ($component -eq '.' -or $component -eq '..')) { return '' }
        if ($component -eq '.' -or $component -eq '..') { continue }
        if ($component.EndsWith('.') -or $component.EndsWith(' ')) { return '' }
        if ($component -match '[<>"\|\?\*:]' -or (Test-DosDeviceComponent $component)) { return '' }
    }
    try { $full = [System.IO.Path]::GetFullPath($p) } catch { return '' }
    if ([string]::IsNullOrEmpty($full) -or $full.Length -gt 4096 -or -not $full.StartsWith('\\', [System.StringComparison]::Ordinal)) { return '' }
    return $full
}

$ProbeCwd = ConvertTo-ProbePath $cwd

function Get-DisplayPath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $short = $Path.Replace('\', '/')
    $homeFwd = $HomeDir.Replace('\', '/').TrimEnd('/')
    if (-not [string]::IsNullOrEmpty($homeFwd)) {
        if ($short.Equals($homeFwd, [System.StringComparison]::OrdinalIgnoreCase)) { $short = '~' }
        elseif ($short.StartsWith($homeFwd + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $short = '~' + $short.Substring($homeFwd.Length) }
    }
    if ($short -eq '/') { return '/' }
    if ($short -match '^[A-Za-z]:/?$') { return $short.Substring(0, 2) + '/' }

    $parts = New-Object System.Collections.Generic.List[string]
    $prefix = ''
    if ($short.StartsWith('//', [System.StringComparison]::Ordinal)) {
        $raw = $short.Substring(2).Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)
        if ($raw.Length -eq 0) { return '//' }
        if ($raw.Length -eq 1) { return '//' + $raw[0] }
        $prefix = '//' + $raw[0] + '/' + $raw[1]
        for ($i = 2; $i -lt $raw.Length; $i++) { [void]$parts.Add($raw[$i]) }
        $logicalCount = 2 + $parts.Count
    } elseif ($short -match '^([A-Za-z]:)(?:/(.*))?$') {
        $prefix = $Matches[1]
        $rest = $Matches[2]
        if (-not [string]::IsNullOrEmpty($rest)) {
            foreach ($part in $rest.Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)) { [void]$parts.Add($part) }
        }
        $logicalCount = 1 + $parts.Count
    } elseif ($short.StartsWith('/', [System.StringComparison]::Ordinal)) {
        $prefix = '/'
        foreach ($part in $short.Substring(1).Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)) { [void]$parts.Add($part) }
        $logicalCount = 1 + $parts.Count
    } elseif ($short -eq '~' -or $short.StartsWith('~/', [System.StringComparison]::Ordinal)) {
        $prefix = '~'
        if ($short.Length -gt 2) {
            foreach ($part in $short.Substring(2).Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)) { [void]$parts.Add($part) }
        }
        $logicalCount = 1 + $parts.Count
    } else {
        foreach ($part in $short.Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)) { [void]$parts.Add($part) }
        $logicalCount = $parts.Count
    }

    if ($logicalCount -le [int]$Cfg.VL_PATH_DEPTH) { return $short.TrimEnd('/') }
    $last = ''
    if ($parts.Count -gt 0) { $last = $parts[$parts.Count - 1] }
    if ($prefix.StartsWith('//', [System.StringComparison]::Ordinal)) { return $prefix + '/' + $G.Ellipsis + '/' + $last }
    if ($prefix -eq '/') {
        $first = ''
        if ($parts.Count -gt 0) { $first = $parts[0] }
        return '/' + $first + '/' + $G.Ellipsis + '/' + $last
    }
    if ($prefix -eq '~' -or $prefix -match '^[A-Za-z]:$') {
        $first = ''
        if ($parts.Count -gt 0) { $first = $parts[0] }
        return $prefix + '/' + $first + '/' + $G.Ellipsis + '/' + $last
    }
    if ($parts.Count -ge 2) { return $parts[0] + '/' + $parts[1] + '/' + $G.Ellipsis + '/' + $last }
    return $short
}

$AppCache = @{}
function Get-ApplicationPath([string]$Name) {
    if ($AppCache.ContainsKey($Name)) { return [string]$AppCache[$Name] }
    $path = ''
    try {
        $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd) { $path = [string]$cmd.Source }
    } catch { $path = '' }
    $AppCache[$Name] = $path
    return $path
}

$env:GIT_OPTIONAL_LOCKS = '0'

function Get-GitState([string]$Cwd) {
    $state = @{ Branch = ''; Marks = ''; Ab = ''; Dirty = $false }
    if ([string]::IsNullOrEmpty($Cwd)) { return $state }
    $git = Get-ApplicationPath 'git'
    if ([string]::IsNullOrEmpty($git)) { return $state }
    try {
        $LASTEXITCODE = 0
        $lines = @(& $git -C $Cwd status --porcelain=v2 --branch 2>$null)
        if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { return $state }
    } catch { return $state }
    $oid = ''
    $head = ''
    $ahead = 0
    $behind = 0
    $staged = $false
    $unstaged = $false
    $untracked = $false
    foreach ($item in $lines) {
        $line = [string]$item
        if ($line.StartsWith('# branch.oid ', [System.StringComparison]::Ordinal)) { $oid = $line.Substring(13) }
        elseif ($line.StartsWith('# branch.head ', [System.StringComparison]::Ordinal)) { $head = $line.Substring(14) }
        elseif ($line.StartsWith('# branch.ab ', [System.StringComparison]::Ordinal)) {
            if ($line -match '\+([0-9]+)[ \t]+-([0-9]+)') {
                [void][int]::TryParse($Matches[1], $IntegerStyle, $Invariant, [ref]$ahead)
                [void][int]::TryParse($Matches[2], $IntegerStyle, $Invariant, [ref]$behind)
            }
        } elseif ($line.StartsWith('? ', [System.StringComparison]::Ordinal)) { $untracked = $true }
        elseif ($line -match '^[12] ') {
            $xy = $line.Substring(2)
            if ($xy.Length -ge 1 -and $xy[0] -ne '.') { $staged = $true }
            if ($xy.Length -ge 2 -and $xy[1] -ne '.') { $unstaged = $true }
        } elseif ($line.StartsWith('u ', [System.StringComparison]::Ordinal)) { $unstaged = $true }
    }
    if ([string]::IsNullOrEmpty($oid)) { return $state }
    if ($head -eq '(detached)' -or [string]::IsNullOrEmpty($head)) { $state.Branch = $oid.Substring(0, [Math]::Min(7, $oid.Length)) }
    else { $state.Branch = Remove-ControlChars $head }
    if ($staged) { $state.Marks += '+' }
    if ($unstaged) { $state.Marks += '!' }
    if ($untracked) { $state.Marks += '?' }
    if ($ahead -gt 0) { $state.Ab += $G.Ahead + [string]$ahead }
    if ($behind -gt 0) { $state.Ab += $G.Behind + [string]$behind }
    if (-not [string]::IsNullOrEmpty($state.Marks)) { $state.Dirty = $true }
    return $state
}

function Get-GitRoot([string]$Cwd) {
    if ([string]::IsNullOrEmpty($Cwd)) { return '' }
    $git = Get-ApplicationPath 'git'
    if ([string]::IsNullOrEmpty($git)) { return '' }
    $root = ''
    try {
        $LASTEXITCODE = 0
        $result = @(& $git -C $Cwd rev-parse --path-format=absolute --git-common-dir 2>$null)
        if ($LASTEXITCODE -eq 0 -and $result.Count -gt 0) { $root = [string]$result[0] }
        if ([string]::IsNullOrEmpty($root)) {
            $LASTEXITCODE = 0
            $result = @(& $git -C $Cwd rev-parse --show-toplevel 2>$null)
            if ($LASTEXITCODE -ne 0 -or $result.Count -eq 0) { return '' }
            $root = [string]$result[0]
        }
    } catch { return '' }
    $root = (Remove-ControlChars $root).Replace('\', '/').TrimEnd('/')
    if ($root.EndsWith('/.git', [System.StringComparison]::OrdinalIgnoreCase)) { $root = $root.Substring(0, $root.Length - 5) }
    $parts = $root.Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Length -eq 0) { return '' }
    return $parts[$parts.Length - 1]
}

function Get-StashCount([string]$Cwd) {
    if ([string]::IsNullOrEmpty($Cwd)) { return 0 }
    $git = Get-ApplicationPath 'git'
    if ([string]::IsNullOrEmpty($git)) { return 0 }
    try {
        $LASTEXITCODE = 0
        $result = @(& $git -C $Cwd rev-list --walk-reflogs --count refs/stash 2>$null)
        if ($LASTEXITCODE -ne 0 -or $result.Count -eq 0) { return 0 }
        return Get-BoundedInt ([string]$result[0]) 0 0 1000000
    } catch { return 0 }
}

function Read-PinFile([string]$Path) {
    try {
        $attrs = [System.IO.File]::GetAttributes($Path)
        if (($attrs -band [System.IO.FileAttributes]::Directory) -ne 0) { return '' }
        $info = New-Object System.IO.FileInfo($Path)
        if ($info.Length -gt 65536) { return '' }
        $reader = New-Object System.IO.StreamReader($Path, $StrictUtf8, $true)
        try { $line = $reader.ReadLine() } finally { $reader.Dispose() }
        return (Remove-ControlChars ([string]$line)).Trim()
    } catch { return '' }
}

function Get-NodeVersion-Uncached([string]$Dir) {
    if ([string]::IsNullOrEmpty($Dir)) { return '' }
    try { $d = New-Object System.IO.DirectoryInfo($Dir) } catch { $d = $null }
    while ($null -ne $d) {
        foreach ($name in @('.nvmrc', '.node-version')) {
            $value = Read-PinFile ([System.IO.Path]::Combine($d.FullName, $name))
            if (-not [string]::IsNullOrEmpty($value)) { return $value.TrimStart('v') }
        }
        $d = $d.Parent
    }
    if ($Cfg.VL_RUNTIME_PROBE -eq '1') {
        $node = Get-ApplicationPath 'node'
        if (-not [string]::IsNullOrEmpty($node)) {
            try {
                $LASTEXITCODE = 0
                $result = @(& $node --version 2>$null)
                if ($LASTEXITCODE -eq 0 -and $result.Count -gt 0) { return (Remove-ControlChars ([string]$result[0])).Trim().TrimStart('v') }
            } catch { }
        }
    }
    return ''
}

function Get-PythonVersion-Uncached([string]$Dir) {
    $venv = Remove-ControlChars ([string]$env:VIRTUAL_ENV)
    if (-not [string]::IsNullOrEmpty($venv)) {
        try { return [System.IO.Path]::GetFileName($venv.TrimEnd('\', '/')) } catch { }
    }
    $conda = Remove-ControlChars ([string]$env:CONDA_DEFAULT_ENV)
    if (-not [string]::IsNullOrEmpty($conda) -and $conda -ne 'base') { return $conda }
    if (-not [string]::IsNullOrEmpty($Dir)) {
        try { $d = New-Object System.IO.DirectoryInfo($Dir) } catch { $d = $null }
        while ($null -ne $d) {
            $value = Read-PinFile ([System.IO.Path]::Combine($d.FullName, '.python-version'))
            if (-not [string]::IsNullOrEmpty($value)) { return $value }
            $d = $d.Parent
        }
    }
    if ($Cfg.VL_RUNTIME_PROBE -eq '1') {
        $python = Get-ApplicationPath 'python3'
        if (-not [string]::IsNullOrEmpty($python)) {
            try {
                $LASTEXITCODE = 0
                $result = @(& $python --version 2>&1)
                if ($LASTEXITCODE -eq 0 -and $result.Count -gt 0) { return ((Remove-ControlChars ([string]$result[0])) -replace '^Python ', '').Trim() }
            } catch { }
        }
    }
    return ''
}

$script:StashCacheSet = $false
$script:StashCache = 0
$script:NodeCacheSet = $false
$script:NodeCache = ''
$script:PythonCacheSet = $false
$script:PythonCache = ''

function Get-StashCount-Cached([string]$Cwd) {
    if (-not $script:StashCacheSet) {
        $script:StashCache = Get-StashCount $Cwd
        $script:StashCacheSet = $true
    }
    return [int]$script:StashCache
}

function Get-NodeVersion([string]$Dir) {
    if (-not $script:NodeCacheSet) {
        $script:NodeCache = [string](Get-NodeVersion-Uncached $Dir)
        $script:NodeCacheSet = $true
    }
    return [string]$script:NodeCache
}

function Get-PythonVersion([string]$Dir) {
    if (-not $script:PythonCacheSet) {
        $script:PythonCache = [string](Get-PythonVersion-Uncached $Dir)
        $script:PythonCacheSet = $true
    }
    return [string]$script:PythonCache
}

function Get-SegmentTokens([string]$List) {
    if ([string]::IsNullOrWhiteSpace($List)) { return @() }
    return @([regex]::Split($List.Trim(), '\s+') | Where-Object { -not [string]::IsNullOrEmpty($_) })
}

$MainSegmentNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$MainSegmentLists = @([string]$Cfg.VL_SEGMENTS, [string]$Cfg.VL_SEGMENTS2, [string]$Cfg.VL_SEGMENTS3)
foreach ($list in $MainSegmentLists) {
    foreach ($name in (Get-SegmentTokens $list)) { [void]$MainSegmentNames.Add($name) }
}
$FloatSegmentNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$FloatTokens = @(Get-SegmentTokens ([string]$Cfg.VL_FLOAT_SEGMENTS))
$FloatEnabled = $Cfg.VL_FLOAT -eq '1' -and ([string]$Cfg.VL_FLOAT_SEGMENTS).Length -le 4096 -and $FloatTokens.Count -le 64 -and ([string]$Cfg.VL_FLOAT_SEP).Length -le 256
if ($FloatEnabled) { foreach ($name in $FloatTokens) { [void]$FloatSegmentNames.Add($name) } }
$ProbeSegmentNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($name in $MainSegmentNames) { [void]$ProbeSegmentNames.Add($name) }
foreach ($name in $FloatSegmentNames) { [void]$ProbeSegmentNames.Add($name) }

# Collision derivation is lexical only and runs even when all state gates are off.
$AllStatePaths = New-Object 'System.Collections.Generic.List[object]'
foreach ($base in @($Cfg.BURN_FILE, $Cfg.RL5H_FILE, $Cfg.RL7D_FILE)) {
    $statePath = Get-StatePaths $base
    if ($null -ne $statePath) { [void]$AllStatePaths.Add($statePath) }
}

$BurnStateGate = $ProbeSegmentNames.Contains('burn')
# burn takes both gates, not just 7d. It can bind to either window, its projection is
# rebound to the synced 5h state, and its own source gate accepts that state, so a
# layout with burn but no limit5h would otherwise leave Limit5 permanently invalid
# and hide the segment for a session with no payload reading but a usable window.
$Limit5StateGate = $Cfg.VL_LIMIT_SYNC -eq '1' -and ($ProbeSegmentNames.Contains('limit5h') -or $BurnStateGate)
$Limit7StateGate = $Cfg.VL_LIMIT_SYNC -eq '1' -and ($ProbeSegmentNames.Contains('limit7d') -or $BurnStateGate)
$State = $null
if ($BurnStateGate -or $Limit5StateGate -or $Limit7StateGate) {
    $State = Get-CorallineState $BurnStateGate $Limit5StateGate $Limit7StateGate
}

$GitState = @{ Branch = ''; Marks = ''; Ab = ''; Dirty = $false }
$GitRoot = ''
if ($ProbeSegmentNames.Contains('git') -or $ProbeSegmentNames.Contains('stash') -or $ProbeSegmentNames.Contains('project')) {
    $GitState = Get-GitState $ProbeCwd
}
if ($ProbeSegmentNames.Contains('project') -and -not [string]::IsNullOrEmpty($GitState.Branch)) { $GitRoot = Get-GitRoot $ProbeCwd }

$SegBgs = New-Object System.Collections.Generic.List[string]
$SegTxt = New-Object System.Collections.Generic.List[string]
$SegLen = New-Object 'System.Collections.Generic.List[int]'

function Remove-Sgr([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return [regex]::Replace($Value, ([string][char]27 + '\[[0-9;]*m'), '')
}

function Get-DisplayWidth([string]$Value) {
    $plain = Remove-Sgr $Value
    $width = 0
    $i = 0
    while ($i -lt $plain.Length) {
        $advance = 1
        try {
            $cp = [char]::ConvertToUtf32($plain, $i)
            if ([char]::IsHighSurrogate($plain[$i])) { $advance = 2 }
        } catch {
            $cp = 0xFFFD
        }
        if ($cp -ge 0x300 -and $cp -le 0x36F -or $cp -ge 0x200B -and $cp -le 0x200F -or $cp -ge 0xFE00 -and $cp -le 0xFE0F) {
            $i += $advance
            continue
        }
        if ($cp -ge 0x1100 -and $cp -le 0x115F -or $cp -ge 0x2E80 -and $cp -le 0xA4CF -or $cp -ge 0xAC00 -and $cp -le 0xD7A3 -or $cp -ge 0xF900 -and $cp -le 0xFAFF -or $cp -ge 0xFE10 -and $cp -le 0xFE19 -or $cp -ge 0xFE30 -and $cp -le 0xFE6F -or $cp -ge 0xFF00 -and $cp -le 0xFF60 -or $cp -ge 0xFFE0 -and $cp -le 0xFFE6 -or $cp -ge 0x1F300 -and $cp -le 0x1FAFF -or $cp -ge 0x20000 -and $cp -le 0x3FFFF) {
            $width += 2
        } else {
            $width++
        }
        $i += $advance
    }
    return $width
}

function Push-Segment([string]$Bg, [string]$Text) {
    [void]$SegBgs.Add($Bg)
    [void]$SegTxt.Add($Text)
    if ($Cfg.VL_LAYOUT -eq 'auto') { [void]$SegLen.Add((Get-DisplayWidth $Text)) }
    else { [void]$SegLen.Add(0) }
}

function Add-DirSegment {
    if ([string]::IsNullOrEmpty($cwd)) { return }
    $short = Get-DisplayPath $cwd
    if ([string]::IsNullOrEmpty($short)) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_DIR "${Bold}${fg} $short ${Norm}"
}

function Add-ProjectSegment {
    if ([string]::IsNullOrEmpty($GitRoot)) {
        if (-not $MainSegmentNames.Contains('dir')) { Add-DirSegment }
        return
    }
    $tr = Get-Trunc $GitRoot ([int]$Cfg.VL_NAME_MAX)
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $bg = $Cfg.VL_BG_PROJECT
    if ([string]::IsNullOrEmpty($bg)) { $bg = $Cfg.VL_BG_DIR }
    Push-Segment $bg "${Bold}${fg} $($Cfg.VL_PROJECT_GLYPH) $tr ${Norm}"
}

function Add-GitSegment {
    if ([string]::IsNullOrEmpty($GitState.Branch)) { return }
    $bg = $Cfg.VL_BG_GIT_OK
    if ($GitState.Dirty) { $bg = $Cfg.VL_BG_GIT_DIRTY }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $tr = Get-Trunc $GitState.Branch ([int]$Cfg.VL_NAME_MAX)
    Push-Segment $bg "${Bold}${fg} $($G.Branch) ${tr}$($GitState.Marks)$($GitState.Ab) ${Norm}"
}

function Add-StashSegment {
    if ([string]::IsNullOrEmpty($GitState.Branch)) { return }
    $count = Get-StashCount-Cached $ProbeCwd
    if ($count -le 0) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $bg = $Cfg.VL_BG_STASH
    if ([string]::IsNullOrEmpty($bg)) { $bg = $Cfg.VL_BG_GIT_OK }
    Push-Segment $bg "${fg} $($G.Flag) $count "
}

function Add-ModelSegment {
    if ([string]::IsNullOrEmpty($model)) { return }
    $shown = $model -replace '^Claude ', ''
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_MODEL "${Bold}${fg} $($G.Diamond) $shown ${Norm}"
}

function Add-EffortSegment {
    if ([string]::IsNullOrEmpty($effort)) { return }
    $label = $effort
    if ($effort -eq 'medium') { $label = 'med' }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_EFFORT "${fg} $($G.Psi) $label "
}

function Add-CtxSegment {
    $pct = 0
    $known = Get-PctValue $ctxPct ([ref]$pct)
    if (-not $known -and ($Cfg.VL_CTX_ALWAYS_SHOW -ne '1' -or -not $JsonParsed -or -not $ctxEmpty)) { return }
    $bar = New-Bar $pct ([int]$Cfg.VL_BAR_WIDTH)
    $pfg = Get-Fg (Get-PctFg $pct)
    $dfg = Get-Fg $Cfg.VL_FG_DIM
    $ti = Format-Tok $tokIn
    $to = Format-Tok $tokOut
    $tcr = Format-Tok $tokCr
    $tcw = Format-Tok $tokCw
    Push-Segment $Cfg.VL_BG_CTX "${pfg} $($Cfg.VL_CTX_GLYPH) ${bar} ${pct}% ${dfg}$($G.Up)${ti} $($G.Down)${to} cr:${tcr} cw:${tcw} "
}

function Add-CacheSegment {
    $pct = 0
    if (-not (Get-PctValue $cacheHit ([ref]$pct))) { return }
    # Inverted thresholds: cache hits are the good outcome, so 98% must read green
    # where the same number on a usage gauge reads red.
    $pfg = Get-Fg (Get-PctFg (100 - $pct))
    # The percentage is the session's cumulative hit ratio, so it stays true after the
    # cache goes cold and is never zeroed. What changes is whether anything about it is
    # still live, and that has to be visible: without a marker a cold pill and a warm
    # one differ only by an absence, which reads as 98% of a cache that is gone.
    # expires_at keeps its last value once the cache goes cold and is absent entirely
    # when the cache never went warm; both are the same thing to read, so both take the
    # marker. Under an hour the countdown carries seconds, because the short TTL is 5
    # minutes and a minute-only countdown would sit on 4m for most of it; from an hour
    # up they are dropped. Format-Countdown is not reused here: it reports an elapsed
    # reset as "now", which is right for a limit window and wrong for a cold cache.
    $dfg = Get-Fg $Cfg.VL_FG_DIM
    $left = "${dfg}cold"
    $ep = ConvertTo-Epoch $cacheExp
    if ($null -ne $ep) {
        $diff = [long]$ep - $Now
        if ($diff -gt 0) {
            $left = "${dfg}$($G.Reset)$(Format-Duration ([double]$diff * 1000) ($diff -lt 3600))"
        }
    }
    $bg = $Cfg.VL_BG_CACHE
    if ([string]::IsNullOrEmpty($bg)) { $bg = $Cfg.VL_BG_CTX }
    Push-Segment $bg "${pfg} $($Cfg.VL_CACHE_GLYPH) ${pct}% ${left} "
}

function Add-LimitSegment([string]$Label, [string]$RawPct, [string]$ResetsAt, [string]$Bg, [int]$PctMilli = -1) {
    $pct = 0
    if ($PctMilli -ge 0) { $pct = [int](Get-RoundEvenInt64 ([long]$PctMilli) 1000L) }
    elseif (-not (Get-PctValue $RawPct ([ref]$pct))) { return }
    $bar = New-Bar $pct ([int]$Cfg.VL_BAR_WIDTH)
    $pfg = Get-Fg (Get-PctFg $pct)
    $countdown = Format-Countdown $ResetsAt
    $reset = ''
    if (-not [string]::IsNullOrEmpty($countdown)) {
        $dfg = Get-Fg $Cfg.VL_FG_DIM
        $reset = "${dfg}$($G.Reset)${countdown}"
    }
    Push-Segment $Bg "${pfg} $Label ${bar} ${pct}% ${reset} "
}

# Synced state overrides the payload but must not gate the segment: a window is
# only Valid while its reset is still ahead, and that holds for the payload
# snapshot and every store entry alike. Claude Code re-renders an idle session
# from its last-seen snapshot, so once a window elapses with no interaction both
# sources fall invalid in the same render and returning here blanked the segment
# until the next keystroke. Fall back to Current*.Elapsed*, which requires both
# the pct and the reset to have passed validation and the reset to have actually
# passed, so neither an unvalidated pct nor an unobserved window reaches the bar.
# Format-Countdown reports an elapsed reset as "now".
# Ownership is decided once, in Select-LimitResult: this session's own reading wins
# its own window and the store wins only with a strictly newer reset. Requiring
# Current*.Valid again here added no protection and removed the store's last job,
# being the sole source when this session has no reading at all. The payload carries
# rate_limits only after the session has received an API response, so a freshly
# started, resumed, or idle session blanked both gauges even though the account-level
# window was known. Borrowing is safe now in a way it was not before: an entry is
# admitted only while its reset is still ahead of Now and every entry it outranks is
# garbage-collected, so no fossil is inherited. What is borrowed is the highest
# percentage any session recorded for the CURRENT window, an over-estimate when
# sessions disagree, which is the accepted cost of showing the account's window
# instead of nothing. Same rule for both windows.
function Add-Limit5Segment {
    if ($Cfg.VL_LIMIT_SYNC -eq '1') {
        if ($null -eq $State) { return }
        if ($State.Limit5.Valid) {
            Add-LimitSegment '5h' (Format-StatePct $State.Limit5.Pct) ([string]$State.Limit5.Reset) $Cfg.VL_BG_5H $State.Limit5.Pct
        } elseif ($State.Current5.Elapsed) {
            Add-LimitSegment '5h' (Format-StatePct $State.Current5.ElapsedPct) ([string]$State.Current5.ElapsedReset) $Cfg.VL_BG_5H $State.Current5.ElapsedPct
        }
        return
    }
    Add-LimitSegment '5h' $fhPct $fhRst $Cfg.VL_BG_5H
}

function Add-Limit7Segment {
    if ($Cfg.VL_LIMIT_SYNC -eq '1') {
        if ($null -eq $State) { return }
        if ($State.Limit7.Valid) {
            Add-LimitSegment '7d' (Format-StatePct $State.Limit7.Pct) ([string]$State.Limit7.Reset) $Cfg.VL_BG_7D $State.Limit7.Pct
        } elseif ($State.Current7.Elapsed) {
            Add-LimitSegment '7d' (Format-StatePct $State.Current7.ElapsedPct) ([string]$State.Current7.ElapsedReset) $Cfg.VL_BG_7D $State.Current7.ElapsedPct
        }
        return
    }
    Add-LimitSegment '7d' $wdPct $wdRst $Cfg.VL_BG_7D
}

function Format-Eta([long]$Seconds) {
    $remainder = 0L
    $days = [Math]::DivRem($Seconds, 86400L, [ref]$remainder)
    $minutesRemainder = 0L
    $hours = [Math]::DivRem($remainder, 3600L, [ref]$minutesRemainder)
    $unused = 0L
    $minutes = [Math]::DivRem($minutesRemainder, 60L, [ref]$unused)
    if ($days -gt 0) { return [string]::Format($Invariant, '{0}d{1:00}h', $days, $hours) }
    if ($hours -gt 0) { return [string]::Format($Invariant, '{0}h{1:00}m', $hours, $minutes) }
    return [string]::Format($Invariant, '{0}m', $minutes)
}

function Add-BurnSegment {
    if ($null -eq $State -or -not $State.Burn.Reported) { return }
    $bg = $Cfg.VL_BG_BURN
    if ([string]::IsNullOrEmpty($bg)) { $bg = $Cfg.VL_BG_5H }
    if ($State.Burn.State -ne 'active') {
        $fg = Get-Fg $Cfg.VL_FG_DIM
        if ($State.Burn.State -eq 'warming') { Push-Segment $bg "${fg} $($Cfg.VL_BURN_GLYPH) $($G.Ellipsis) " }
        else { Push-Segment $bg "${fg} $($Cfg.VL_BURN_GLYPH) $($G.Check) " }
        return
    }
    $window = 604800L
    if ($State.Burn.Label -eq '5h') { $window = 18000L }
    $eta = [long]$State.Burn.Eta
    $ttr = [long]$State.Burn.Ttr
    if ($eta -gt $window) {
        $fg = Get-Fg $Cfg.VL_FG_OK
        Push-Segment $bg "${fg} $($Cfg.VL_BURN_GLYPH) $($G.Check) "
        return
    }
    if ($eta -le $ttr) { $color = $Cfg.VL_FG_HOT }
    elseif ((10L * $ttr) -ge (8L * $eta)) { $color = $Cfg.VL_FG_WARN }
    else { $color = $Cfg.VL_FG_OK }
    $fg = Get-Fg $color
    Push-Segment $bg "${fg} $($Cfg.VL_BURN_GLYPH) $($State.Burn.Label) $($G.BurnTo) $(Format-Eta $eta) "
}

function Add-CostSegment {
    $value = 0.0
    if ($costKind -eq 'missing') {
        if (-not $JsonParsed -or $Cfg.VL_COST_ALWAYS_SHOW -ne '1') { return }
    } elseif ($costKind -eq 'scalar') {
        $raw = [string]$costRaw
        if ($raw.Length -gt 128 -or $raw -cnotmatch '\A *[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)? *\z') { return }
        $trimmed = $raw.Trim(' ')
        $eIndex = $trimmed.IndexOf('e')
        $upperIndex = $trimmed.IndexOf('E')
        if ($eIndex -lt 0 -or ($upperIndex -ge 0 -and $upperIndex -lt $eIndex)) { $eIndex = $upperIndex }
        $significand = $trimmed
        if ($eIndex -ge 0) { $significand = $trimmed.Substring(0, $eIndex) }
        $lexicalNonZero = $significand -match '[1-9]'
        if ($trimmed[0] -eq '-' -and $lexicalNonZero) { return }
        $explicitExponent = 0
        if ($eIndex -ge 0) {
            $expText = $trimmed.Substring($eIndex + 1)
            $expNegative = $expText[0] -eq '-'
            if ($expText[0] -eq '+' -or $expNegative) { $expText = $expText.Substring(1) }
            $expText = $expText.TrimStart('0')
            if ([string]::IsNullOrEmpty($expText)) { $expText = '0' }
            if ($expText.Length -gt 3) { return }
            $expMagnitude = [int]$expText
            if ($expMagnitude -gt 308) { return }
            $explicitExponent = $expMagnitude
            if ($expNegative) { $explicitExponent = -$explicitExponent }
        }
        if ($lexicalNonZero) {
            $unsignedSignificand = $significand
            if ($unsignedSignificand[0] -eq '+' -or $unsignedSignificand[0] -eq '-') { $unsignedSignificand = $unsignedSignificand.Substring(1) }
            $dotIndex = $unsignedSignificand.IndexOf('.')
            $integerDigits = $unsignedSignificand.Length
            if ($dotIndex -ge 0) { $integerDigits = $dotIndex }
            $digits = $unsignedSignificand.Replace('.', '')
            $firstNonZero = $digits.IndexOfAny([char[]]'123456789')
            $adjustedExponent = $explicitExponent + $integerDigits - $firstNonZero - 1
            if ($adjustedExponent -lt -323 -or $adjustedExponent -gt 9) { return }
            if ($adjustedExponent -eq 9 -and $digits.Substring($firstNonZero) -cnotmatch '\A10*\z') { return }
        }
        if (-not (Try-BoundedDouble $raw 0 1000000000 ([ref]$value))) { return }
        if ($value -eq 0.0) {
            if ($lexicalNonZero) { return }
            $value = 0.0
            if ($Cfg.VL_COST_ALWAYS_SHOW -ne '1') { return }
        }
    } else { return }
    $format = '$' + $value.ToString('F' + $Cfg.VL_COST_DECIMALS, $Invariant)
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_COST "${fg} $format "
}

function Add-ClockSegment {
    if ($Cfg.VL_CLOCK -ceq 'off') { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_CLOCK "${fg} $($G.Dot) $(Get-ClockText) "
}

function Get-NonNegativeLong([string]$Raw) {
    $value = 0L
    if (-not [long]::TryParse($Raw, $IntegerStyle, $Invariant, [ref]$value) -or $value -lt 0 -or $value -gt 1000000000000000) { return 0L }
    return $value
}

function Add-LinesSegment {
    $add = Get-NonNegativeLong $linesAdd
    $del = Get-NonNegativeLong $linesDel
    if ($add -le 0 -and $del -le 0) { return }
    $ok = Get-Fg $Cfg.VL_FG_OK
    $hot = Get-Fg $Cfg.VL_FG_HOT
    Push-Segment $Cfg.VL_BG_LINES " ${ok}+${add} ${hot}-${del} "
}

function Add-StyleSegment {
    if ([string]::IsNullOrEmpty($outStyle) -or $outStyle -eq 'default') { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_STYLE "${fg} $($G.Pencil) $outStyle "
}

function Add-DurationSegment {
    $value = 0.0
    if (-not (Try-BoundedDouble $durMs 0 1000000000000000 ([ref]$value)) -or $value -le 0) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_DURATION "${fg} $($G.Hourglass) $(Format-Duration $value $false) "
}

function Add-NodeSegment {
    $version = Get-NodeVersion $ProbeCwd
    if ([string]::IsNullOrEmpty($version)) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $bg = $Cfg.VL_BG_NODE
    if ([string]::IsNullOrEmpty($bg)) { $bg = $Cfg.VL_BG_MODEL }
    Push-Segment $bg "${fg} $($Cfg.VL_NODE_GLYPH) $version "
}

function Add-PythonSegment {
    if ([string]::IsNullOrEmpty($ProbeCwd)) { return }
    $version = Get-PythonVersion $ProbeCwd
    if ([string]::IsNullOrEmpty($version)) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $bg = $Cfg.VL_BG_PYTHON
    if ([string]::IsNullOrEmpty($bg)) { $bg = $Cfg.VL_BG_MODEL }
    Push-Segment $bg "${fg} $($Cfg.VL_PY_GLYPH) $version "
}

$SegmentBuilders = [ordered]@{
    burn = { Add-BurnSegment }
    cache = { Add-CacheSegment }
    clock = { Add-ClockSegment }
    cost = { Add-CostSegment }
    ctx = { Add-CtxSegment }
    dir = { Add-DirSegment }
    duration = { Add-DurationSegment }
    effort = { Add-EffortSegment }
    git = { Add-GitSegment }
    limit5h = { Add-Limit5Segment }
    limit7d = { Add-Limit7Segment }
    lines = { Add-LinesSegment }
    model = { Add-ModelSegment }
    node = { Add-NodeSegment }
    project = { Add-ProjectSegment }
    python = { Add-PythonSegment }
    stash = { Add-StashSegment }
    style = { Add-StyleSegment }
}
$SupportedSegmentNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($name in $SegmentBuilders.Keys) { [void]$SupportedSegmentNames.Add([string]$name) }

function Build-Segments([string]$List) {
    $SegBgs.Clear()
    $SegTxt.Clear()
    $SegLen.Clear()
    foreach ($name in (Get-SegmentTokens $List)) {
        if ($SupportedSegmentNames.Contains($name)) { & $SegmentBuilders[$name] }
    }
}

function Render-Range([int]$Start, [int]$End) {
    if ($SegBgs.Count -eq 0 -or $Start -lt 0 -or $End -lt $Start -or $End -ge $SegBgs.Count) { return '' }
    if ($Cfg.VL_STYLE -eq 'lean') {
        $lbg = ''
        if (-not [string]::IsNullOrEmpty($Cfg.VL_LEAN_BG)) { $lbg = Get-Bg $Cfg.VL_LEAN_BG }
        $out = ''
        if (-not [string]::IsNullOrEmpty($lbg) -and -not [string]::IsNullOrEmpty($Cfg.VL_LEAN_CAP_L)) {
            $out = $Rst + (Get-Fg $Cfg.VL_LEAN_BG) + $Cfg.VL_LEAN_CAP_L
        }
        for ($i = $Start; $i -le $End; $i++) {
            $out += $Rst + $lbg + (Get-Fg $SegBgs[$i]) + $SegTxt[$i]
            if ($i -lt $End) { $out += $Rst + $lbg + $Cfg.VL_LEAN_SEP }
        }
        if (-not [string]::IsNullOrEmpty($lbg) -and -not [string]::IsNullOrEmpty($Cfg.VL_LEAN_CAP_R)) {
            $out += $Rst + (Get-Fg $Cfg.VL_LEAN_BG) + $Cfg.VL_LEAN_CAP_R
        }
        return $out + $Rst
    }
    $out = $Rst + (Get-Fg $SegBgs[$Start]) + $Cfg.VL_CAP_L
    for ($i = $Start; $i -le $End; $i++) {
        $out += (Get-Bg $SegBgs[$i]) + $SegTxt[$i]
        if ($i -lt $End) {
            $out += (Get-Bg $SegBgs[$i + 1]) + (Get-Fg $SegBgs[$i]) + $Cfg.VL_SEP
        }
    }
    $out += $Rst + (Get-Fg $SegBgs[$End]) + $Cfg.VL_CAP_R + $Rst
    return $out
}

function Get-ScalarCount([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return 0 }
    $count = 0
    $i = 0
    while ($i -lt $Value.Length) {
        if ([char]::IsHighSurrogate($Value[$i]) -and $i + 1 -lt $Value.Length -and [char]::IsLowSurrogate($Value[$i + 1])) { $i++ }
        $count++
        $i++
    }
    return $count
}

function Test-FloatCollision([string]$Target) {
    $runtime = ''
    try { $runtime = [IO.Path]::GetFullPath($ScriptPath) } catch { }
    $collisionPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in @($ConfigPath, $runtime)) { if (-not [string]::IsNullOrEmpty($path)) { [void]$collisionPaths.Add($path) } }
    foreach ($path in $ConfigVisitedPaths) { if (-not [string]::IsNullOrEmpty([string]$path)) { [void]$collisionPaths.Add([string]$path) } }
    foreach ($statePath in $AllStatePaths) {
        if ($null -eq $statePath) { continue }
        foreach ($path in @($statePath.Base, $statePath.Root)) { if (-not [string]::IsNullOrEmpty($path)) { [void]$collisionPaths.Add($path) } }
    }
    foreach ($path in $collisionPaths) {
        if ($Target.Equals([string]$path, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-FloatTarget {
    if (-not $FloatEnabled) { return $null }
    if ($FloatFileRootAuthorized -and [string]::IsNullOrEmpty([string]$Cfg.VL_FLOAT_FILE)) { return $null }
    if (([string]$Cfg.VL_FLOAT_FILE).Length -gt 4096) { return $null }
    $target = ConvertTo-LocalFullPath ([string]$Cfg.VL_FLOAT_FILE) ([Environment]::CurrentDirectory)
    if ([string]::IsNullOrEmpty($target) -or (Test-FloatCollision $target)) { return $null }
    return $target
}

function Write-FloatAtomic([string]$Target, [byte[]]$Bytes) {
    $parent = $null
    try { $parent = [IO.Path]::GetDirectoryName($Target) } catch { return $false }
    if ([string]::IsNullOrEmpty($parent) -or -not (Test-NoReparseComponents $parent)) { return $false }
    try {
        # WIN03_TEST_BEFORE_PARENT_CREATE
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    } catch { return $false }
    # WIN03_TEST_AFTER_PARENT_CREATE
    if (-not (Test-NoReparseComponents $parent) -or -not [IO.Directory]::Exists($parent)) { return $false }
    if ((Test-StateObjectExists $Target) -and -not (Test-SafeRegularFile $Target)) { return $false }

    $temp = ''
    $backup = ''
    try {
        for ($attempt = 0; $attempt -lt 8; $attempt++) {
            $candidate = [IO.Path]::Combine($parent, '.float.tmp.' + [string]$PID + '.' + [guid]::NewGuid().ToString('N'))
            if ($candidate.Length -gt 4096) { return $false }
            $stream = $null
            try {
                $stream = New-Object IO.FileStream($candidate, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
                if ($Bytes.Length -gt 0) { $stream.Write($Bytes, 0, $Bytes.Length) }
                $stream.Flush($true)
                $stream.Dispose()
                $stream = $null
                # WIN03_TEST_AFTER_TEMP_CLOSE
                $temp = $candidate
                break
            } catch [IO.IOException] {
                if ($null -ne $stream) { $stream.Dispose() }
            } catch {
                if ($null -ne $stream) { $stream.Dispose() }
                return $false
            }
        }
        if ([string]::IsNullOrEmpty($temp)) { return $false }
        if (-not (Test-NoReparseComponents $parent)) { return $false }
        if (Test-StateObjectExists $Target) {
            if (-not (Test-SafeRegularFile $Target)) { return $false }
            for ($attempt = 0; $attempt -lt 8; $attempt++) {
                $backup = [IO.Path]::Combine($parent, '.float.bak.' + [string]$PID + '.' + [guid]::NewGuid().ToString('N'))
                if ($backup.Length -gt 4096) { $backup = ''; return $false }
                if (-not (Test-StateObjectExists $backup)) { break }
                $backup = ''
            }
            if ([string]::IsNullOrEmpty($backup)) { return $false }
            [IO.File]::Replace($temp, $Target, $backup)
            if (Test-SafeRegularFile $backup) { [IO.File]::Delete($backup); $backup = '' }
            elseif (-not (Test-StateObjectExists $backup)) { $backup = '' }
        } else {
            [IO.File]::Move($temp, $Target)
        }
        $temp = ''
        return $true
    } catch { return $false }
    finally {
        foreach ($path in @($temp, $backup)) {
            if (-not [string]::IsNullOrEmpty($path)) {
                try {
                    if (Test-SafeRegularFile $path) { [IO.File]::Delete($path) }
                } catch { }
            }
        }
    }
}

function Test-FloatText([string]$Value) {
    if ($null -eq $Value) { return $false }
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 0x20 -or $code -eq 0x7F -or $code -ge 0x80 -and $code -le 0x9F -or $code -eq 0x1B) { return $true }
    }
    return $false
}

function Invoke-Float {
    if (-not $FloatEnabled) { return }
    $target = Get-FloatTarget
    if ([string]::IsNullOrEmpty($target)) { return }
    $oldNoColor = $NoColor
    $oldBold = $Bold
    $oldNorm = $Norm
    $oldRst = $Rst
    $oldLayout = $Cfg.VL_LAYOUT
    try {
        $NoColor = $true
        $Bold = ''
        $Norm = ''
        $Rst = ''
        $Cfg.VL_LAYOUT = 'fixed'
        Build-Segments ([string]$Cfg.VL_FLOAT_SEGMENTS)
        $parts = New-Object 'System.Collections.Generic.List[string]'
        for ($i = 0; $i -lt $SegTxt.Count; $i++) {
            $plain = (Remove-Sgr ([string]$SegTxt[$i])).Trim()
            if ([string]::IsNullOrEmpty($plain)) { continue }
            if (Test-FloatText $plain) { return }
            [void]$parts.Add($plain)
        }
        $line = [string]::Join([string]$Cfg.VL_FLOAT_SEP, $parts.ToArray())
        if (Test-FloatText $line) { return }
        $payload = $line + "`n"
        $bytes = $StrictUtf8.GetBytes($payload)
        if ($bytes.Length -gt 65536) { return }
        [void](Write-FloatAtomic $target $bytes)
    } catch { }
    finally {
        $NoColor = $oldNoColor
        $Bold = $oldBold
        $Norm = $oldNorm
        $Rst = $oldRst
        $Cfg.VL_LAYOUT = $oldLayout
    }
}

function Get-TerminalColumns {
    $raw = [string]$env:COLUMNS
    if (-not [string]::IsNullOrEmpty($raw)) {
        if ($raw -notmatch '^([0-9]+)$') { return 0 }
        $value = 0
        if (-not [int]::TryParse($raw, $IntegerStyle, $Invariant, [ref]$value) -or $value -lt 1 -or $value -gt 32767) { return 0 }
        return $value
    }
    if ($Host.Name -ne 'ConsoleHost') { return 0 }
    try {
        $value = [int]$Host.UI.RawUI.WindowSize.Width
        if ($value -ge 1 -and $value -le 32767) { return $value }
    } catch { }
    return 0
}

try {
    Invoke-Float
    if ($Cfg.VL_LAYOUT -eq 'auto') {
        Build-Segments ([string]$Cfg.VL_SEGMENTS)
        $total = $SegBgs.Count
        if ($total -gt 0) {
            $width = Get-TerminalColumns
            $maxLines = [int]$Cfg.VL_MAX_LINES
            if ($width -le 0 -or $maxLines -le 1) {
                $OutputWriter.WriteLine((Render-Range 0 ($total - 1)))
            } else {
                $width -= [int]$Cfg.VL_WRAP_MARGIN
                if ($width -lt 1) { $width = 1 }
                if ($Cfg.VL_STYLE -eq 'lean') {
                    $capWidth = (Get-ScalarCount $Cfg.VL_LEAN_CAP_L) + (Get-ScalarCount $Cfg.VL_LEAN_CAP_R)
                    $sepWidth = Get-ScalarCount $Cfg.VL_LEAN_SEP
                } else {
                    $capWidth = 2
                    $sepWidth = 1
                }
                $start = 0
                $line = 1
                $current = $capWidth + [int]$SegLen[0]
                for ($i = 1; $i -lt $total; $i++) {
                    $need = $current + $sepWidth + [int]$SegLen[$i]
                    if ($need -gt $width -and $line -lt $maxLines) {
                        $OutputWriter.WriteLine((Render-Range $start ($i - 1)))
                        $start = $i
                        $line++
                        $current = $capWidth + [int]$SegLen[$i]
                    } else { $current = $need }
                }
                $OutputWriter.WriteLine((Render-Range $start ($total - 1)))
            }
        }
    } else {
        foreach ($list in $MainSegmentLists) {
            if ([string]::IsNullOrWhiteSpace($list)) { continue }
            Build-Segments $list
            if ($SegBgs.Count -gt 0) { $OutputWriter.WriteLine((Render-Range 0 ($SegBgs.Count - 1))) }
        }
    }
} finally {
    $OutputWriter.Flush()
    $OutputWriter.Dispose()
}

exit 0
