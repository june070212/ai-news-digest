<#
.SYNOPSIS
    Detection / compliance rule for the gitleaks pre-commit hook package.

.DESCRIPTION
    Compliant only when every layer is in place:
      * gitleaks.exe present and executable
      * the managed pre-commit hook exists and carries the managed marker
      * system-scope core.hooksPath points at the managed hook directory

    Writes "Installed" and exits 0 when compliant; emits nothing otherwise,
    which SCCM reads as not detected / non-compliant.

.NOTES
    Use as an Application detection method or as the discovery script of a
    Configuration Item paired with Install-GitleaksHook.ps1 for remediation.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GitleaksExe = Join-Path $env:ProgramFiles 'Gitleaks\gitleaks.exe'
$HooksDir    = Join-Path $env:ProgramData 'CopilotPolicy\git-hooks'
$HookFile    = Join-Path $HooksDir 'pre-commit'

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
    if (-not (Test-Path -LiteralPath $GitleaksExe)) { exit 0 }
    if (-not (Test-Path -LiteralPath $HookFile))    { exit 0 }

    $hook = Get-Content -LiteralPath $HookFile -Raw
    if ($hook -notmatch 'deployed by Configuration Manager') { exit 0 }
    if ($hook -notmatch [regex]::Escape(($GitleaksExe -replace '\\', '/'))) { exit 0 }

    $gitExe = Resolve-GitExe
    if (-not $gitExe) { exit 0 }

    $configured = & $gitExe config --system --get core.hooksPath 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $configured) { exit 0 }

    $expected = ($HooksDir -replace '\\', '/')
    if ($configured.Trim().Replace('\', '/').TrimEnd('/') -ne $expected.TrimEnd('/')) { exit 0 }

    Write-Output 'Installed'
    exit 0
}
catch {
    exit 0
}
