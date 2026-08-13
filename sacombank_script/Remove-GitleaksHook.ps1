<#
.SYNOPSIS
    Removes the gitleaks pre-commit hook deployment.

.DESCRIPTION
    Uninstall program for the SCCM Application, or rollback after a bad
    deployment. Clears the system core.hooksPath only when it still points at
    the managed directory, so a hooks path set by another team survives.

.PARAMETER KeepDetectionLog
    Preserve %ProgramData%\CopilotPolicy\logs for forensics.

.NOTES
    Exit codes: 0 = success, 1 = failure. Run 64-bit.
#>

[CmdletBinding()]
param(
    [switch] $KeepDetectionLog,
    [string] $LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:ProgramFiles 'Gitleaks'
$PolicyRoot = Join-Path $env:ProgramData 'CopilotPolicy'
$HooksDir   = Join-Path $PolicyRoot 'git-hooks'
$ConfigFile = Join-Path $PolicyRoot 'gitleaks.toml'
$LogsDir    = Join-Path $PolicyRoot 'logs'

if (-not $LogPath) {
    $ccmLogs = Join-Path $env:WinDir 'CCM\Logs'
    $logDir  = if (Test-Path $ccmLogs) { $ccmLogs } else { Join-Path $env:WinDir 'Logs' }
    $LogPath = Join-Path $logDir 'Install-GitleaksHook.log'
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string] $Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

function Resolve-GitExe {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    foreach ($c in @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe')
    )) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

try {
    Write-Log '--- Remove-GitleaksHook starting ---'

    $gitExe = Resolve-GitExe
    if ($gitExe) {
        $configured = & $gitExe config --system --get core.hooksPath 2>$null
        $expected   = ($HooksDir -replace '\\', '/')

        if ($configured -and
            $configured.Trim().Replace('\', '/').TrimEnd('/') -eq $expected.TrimEnd('/')) {
            & $gitExe config --system --unset core.hooksPath
            Write-Log 'Cleared system core.hooksPath'
        }
        elseif ($configured) {
            Write-Log "System core.hooksPath is '$configured', not ours - left in place" -Level WARN
        }
    }
    else {
        Write-Log 'git.exe not found; skipping core.hooksPath cleanup' -Level WARN
    }

    foreach ($path in @($HooksDir, $ConfigFile, $InstallDir)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
            Write-Log "Removed $path"
        }
    }

    if (-not $KeepDetectionLog -and (Test-Path -LiteralPath $LogsDir)) {
        Remove-Item -LiteralPath $LogsDir -Recurse -Force
        Write-Log "Removed $LogsDir"
    }

    if ((Test-Path -LiteralPath $PolicyRoot) -and
        -not (Get-ChildItem -LiteralPath $PolicyRoot -Force)) {
        Remove-Item -LiteralPath $PolicyRoot -Force
        Write-Log "Removed empty $PolicyRoot"
    }

    Write-Log '--- Remove-GitleaksHook finished (0) ---'
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    Write-Log '--- Remove-GitleaksHook failed (1) ---'
    exit 1
}
