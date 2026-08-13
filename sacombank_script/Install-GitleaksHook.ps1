<#
.SYNOPSIS
    Deploys gitleaks and a machine-wide Git pre-commit hook that blocks commits
    containing hardcoded credentials.

.DESCRIPTION
    Companion to Apply-CopilotPolicy.ps1. Runs as an SCCM Application, Package
    program, or Configuration Item remediation under SYSTEM.

    What it installs:

      1. %ProgramFiles%\Gitleaks\gitleaks.exe
         Copied from the package source, or downloaded from GitHub Releases
         when -DownloadIfMissing is supplied.

      2. %ProgramData%\CopilotPolicy\git-hooks\pre-commit
         POSIX hook run by Git for Windows. Scans the staged diff and aborts
         the commit when a secret is found.

      3. git config --system core.hooksPath
         Points every user on the machine at the hook directory. Written to the
         system gitconfig, so it applies to all profiles without touching each
         user's %USERPROFILE%\.gitconfig.

      4. %ProgramData%\CopilotPolicy\gitleaks.toml (optional baseline allowlist)

    Detections are written to %ProgramData%\CopilotPolicy\logs and, unless
    -NoEventLog is supplied, raised as Application event log entries under the
    source "GitleaksPreCommit" (event ID 1001) so a SIEM agent can alert on them.

.PARAMETER GitleaksSource
    Path to gitleaks.exe in the SCCM content source. Defaults to .\gitleaks.exe
    next to this script.

.PARAMETER DownloadIfMissing
    Download gitleaks from GitHub Releases when GitleaksSource is absent.
    Requires internet access from the client; prefer shipping the binary in the
    package for locked-down fleets.

.PARAMETER Version
    Gitleaks version to download. Used only with -DownloadIfMissing.

.PARAMETER AuditOnly
    Log and alert but let the commit through. Use for a pilot ring before you
    switch the fleet to blocking.

.PARAMETER NoEventLog
    Skip Windows event log entries; file logging only.

.PARAMETER FailClosed
    Block the commit when gitleaks itself is missing or unusable, instead of
    warning and letting it through. Use once the fleet rollout is complete.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Install-GitleaksHook.ps1

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Install-GitleaksHook.ps1 -AuditOnly

.NOTES
    Exit codes: 0 = success, 1 = failure. Run 64-bit, as SYSTEM.

    Known limits, by design of Git itself:
      * "git commit --no-verify" skips all hooks. Treat this as a speed bump on
        the endpoint and keep GitHub push protection as the enforcing control.
      * A user-level or repo-level core.hooksPath overrides the system value.
        Detect-GitleaksHook.ps1 only validates the system scope; run a CI on a
        schedule so drift is re-remediated.
      * core.hooksPath replaces a repository's own .git/hooks, so the deployed
        hook chains to .git/hooks/pre-commit when one exists.
#>

[CmdletBinding()]
param(
    [string] $GitleaksSource,
    [switch] $DownloadIfMissing,
    [string] $Version = '8.28.0',
    [switch] $AuditOnly,
    [switch] $NoEventLog,
    [switch] $FailClosed,
    [string] $LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir  = Join-Path $env:ProgramFiles 'Gitleaks'
$GitleaksExe = Join-Path $InstallDir 'gitleaks.exe'
$PolicyRoot  = Join-Path $env:ProgramData 'CopilotPolicy'
$HooksDir    = Join-Path $PolicyRoot 'git-hooks'
$HookFile    = Join-Path $HooksDir 'pre-commit'
$ConfigFile  = Join-Path $PolicyRoot 'gitleaks.toml'
$DetectionLog = Join-Path $PolicyRoot 'logs\gitleaks-precommit.log'

if (-not $GitleaksSource) {
    $GitleaksSource = Join-Path $PSScriptRoot 'gitleaks.exe'
}

#region logging -------------------------------------------------------------

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
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

#endregion

#region hook template -------------------------------------------------------

# Git for Windows runs hooks under its bundled bash, so the hook is POSIX sh.
# Tokens are substituted below; keep the here-string single quoted so that
# nothing is expanded by PowerShell.
$hookTemplate = @'
#!/bin/sh
#
# Managed pre-commit hook - deployed by Configuration Manager. Do not edit.
# Blocks commits that contain hardcoded credentials, detected with gitleaks.
#
# Bypass with "git commit --no-verify" is logged upstream by GitHub push
# protection, not here; this hook cannot observe its own bypass.

GITLEAKS_BIN="__GITLEAKS_BIN__"
GITLEAKS_CONFIG="__GITLEAKS_CONFIG__"
DETECTION_LOG="__DETECTION_LOG__"
AUDIT_ONLY=__AUDIT_ONLY__
USE_EVENTLOG=__USE_EVENTLOG__
FAIL_CLOSED=__FAIL_CLOSED__

log_line() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$DETECTION_LOG" 2>/dev/null
}

# Chain to a repository's own .git/hooks/pre-commit, which core.hooksPath would
# otherwise shadow. Note "git rev-parse --git-path hooks" resolves to
# core.hooksPath, so derive the repository hook directory from --git-dir.
run_repo_hook() {
    git_dir="$(git rev-parse --git-dir 2>/dev/null)"
    [ -n "$git_dir" ] || return 0
    repo_hook="$git_dir/hooks/pre-commit"
    # Guard against re-entry if the managed hook is also the repository hook.
    if [ -x "$repo_hook" ] && [ "$repo_hook" != "$0" ]; then
        "$repo_hook" || return $?
    fi
    return 0
}

if [ ! -x "$GITLEAKS_BIN" ]; then
    log_line WARN "gitleaks missing at $GITLEAKS_BIN; scan skipped in $(pwd)"
    if [ "$FAIL_CLOSED" = "1" ]; then
        printf '\n' >&2
        printf '  Commit blocked: the managed secret scanner is missing.\n' >&2
        printf '  Expected %s - contact IT Support.\n' "$GITLEAKS_BIN" >&2
        printf '\n' >&2
        exit 1
    fi
    printf 'pre-commit: gitleaks is not installed at %s - secret scan skipped.\n' "$GITLEAKS_BIN" >&2
    run_repo_hook
    exit $?
fi

# gitleaks 8.19 renamed "protect --staged" to "git --staged". Support both so
# the hook keeps working across binary versions in the fleet.
if "$GITLEAKS_BIN" git --help >/dev/null 2>&1; then
    set -- git --pre-commit --staged
else
    set -- protect --staged
fi

config_args=""
if [ -f "$GITLEAKS_CONFIG" ]; then
    config_args="--config=$GITLEAKS_CONFIG"
fi

scan_output="$("$GITLEAKS_BIN" "$@" --redact --no-banner $config_args 2>&1)"
scan_status=$?

if [ $scan_status -eq 0 ]; then
    run_repo_hook
    exit $?
fi

repo_name="$(git rev-parse --show-toplevel 2>/dev/null)"
log_line ALERT "secret detected by $(git config user.email 2>/dev/null) in ${repo_name:-unknown}"
printf '%s\n' "$scan_output" >> "$DETECTION_LOG" 2>/dev/null

if [ "$USE_EVENTLOG" = "1" ] && command -v eventcreate.exe >/dev/null 2>&1; then
    eventcreate.exe /T WARNING /ID 1001 /L APPLICATION /SO GitleaksPreCommit \
        /D "Hardcoded secret blocked in ${repo_name:-unknown} by ${USERNAME:-unknown}" \
        >/dev/null 2>&1
fi

printf '\n'
printf '  Commit blocked: a hardcoded credential was detected.\n' >&2
printf '\n' >&2
printf '%s\n' "$scan_output" >&2
printf '\n' >&2
printf '  Remove the secret, rotate it if it was ever real, and commit again.\n' >&2
printf '  A false positive can be allowlisted in %s - contact IT Security.\n' "$GITLEAKS_CONFIG" >&2
printf '\n' >&2

if [ "$AUDIT_ONLY" = "1" ]; then
    printf '  Audit mode: the commit is allowed, but this event was reported.\n' >&2
    run_repo_hook
    exit $?
fi

exit 1
'@

#endregion

#region helpers -------------------------------------------------------------

function Resolve-GitExe {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Install-GitleaksBinary {
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $GitleaksSource) {
        Copy-Item -LiteralPath $GitleaksSource -Destination $GitleaksExe -Force
        Write-Log "Copied gitleaks from $GitleaksSource"
    }
    elseif ($DownloadIfMissing) {
        $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x32' }
        $url  = "https://github.com/gitleaks/gitleaks/releases/download/v$Version/gitleaks_${Version}_windows_${arch}.zip"
        $tmp  = Join-Path $env:TEMP "gitleaks_$Version.zip"

        Write-Log "Downloading $url"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing

        $extract = Join-Path $env:TEMP "gitleaks_$Version"
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        Expand-Archive -LiteralPath $tmp -DestinationPath $extract -Force

        $found = Get-ChildItem -LiteralPath $extract -Filter 'gitleaks.exe' -Recurse |
                 Select-Object -First 1
        if (-not $found) { throw "gitleaks.exe not found inside $tmp" }

        Copy-Item -LiteralPath $found.FullName -Destination $GitleaksExe -Force
        Remove-Item -LiteralPath $tmp, $extract -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Installed gitleaks $Version from GitHub Releases"
    }
    else {
        throw "gitleaks.exe not found at $GitleaksSource. Ship it in the package content or pass -DownloadIfMissing."
    }

    # Binary must not be user-writable, or a dev could neuter the scan.
    & icacls.exe $InstallDir /inheritance:r /grant:r `
        'SYSTEM:(OI)(CI)(F)' 'BUILTIN\Administrators:(OI)(CI)(F)' 'BUILTIN\Users:(OI)(CI)(RX)' | Out-Null

    $reported = & $GitleaksExe version 2>&1
    Write-Log "gitleaks reports version: $reported"
}

function Install-Hook {
    foreach ($dir in @($PolicyRoot, $HooksDir, (Split-Path -Parent $DetectionLog))) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
    }

    # Git bash reads these paths, so hand it forward slashes.
    $hook = $hookTemplate.
        Replace('__GITLEAKS_BIN__',    ($GitleaksExe  -replace '\\', '/')).
        Replace('__GITLEAKS_CONFIG__', ($ConfigFile   -replace '\\', '/')).
        Replace('__DETECTION_LOG__',   ($DetectionLog -replace '\\', '/')).
        Replace('__AUDIT_ONLY__',      $(if ($AuditOnly)  { '1' } else { '0' })).
        Replace('__USE_EVENTLOG__',    $(if ($NoEventLog) { '0' } else { '1' })).
        Replace('__FAIL_CLOSED__',     $(if ($FailClosed) { '1' } else { '0' }))

    # LF endings and no BOM, otherwise bash fails on the shebang line.
    $hook = $hook -replace "`r`n", "`n"
    [IO.File]::WriteAllText($HookFile, $hook, (New-Object Text.UTF8Encoding $false))
    Write-Log "Wrote hook $HookFile (AuditOnly=$($AuditOnly.IsPresent), FailClosed=$($FailClosed.IsPresent))"

    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        $toml = @'
# Managed gitleaks configuration. Extends the built-in ruleset; add
# organisation-specific rules or allowlist entries below.
[extend]
useDefault = true

[allowlist]
description = "Paths that never contain live credentials"
paths = [
    '''(.*?)(test|spec|fixture|sample|example)(.*?)\.(json|ya?ml|xml|txt)$''',
    '''(.*?)\.md$''',
]
'@
        Set-Content -LiteralPath $ConfigFile -Value $toml -Encoding UTF8 -Force
        Write-Log "Wrote baseline config $ConfigFile"
    }
    else {
        Write-Log "Config $ConfigFile already present, left untouched"
    }

    # Hook and config: read-only for users. The detection log must stay
    # writable by users, because the hook runs in the developer's context.
    & icacls.exe $HooksDir /inheritance:r /grant:r `
        'SYSTEM:(OI)(CI)(F)' 'BUILTIN\Administrators:(OI)(CI)(F)' 'BUILTIN\Users:(OI)(CI)(RX)' | Out-Null
    & icacls.exe $ConfigFile /inheritance:r /grant:r `
        'SYSTEM:(F)' 'BUILTIN\Administrators:(F)' 'BUILTIN\Users:(RX)' | Out-Null
    & icacls.exe (Split-Path -Parent $DetectionLog) /inheritance:r /grant:r `
        'SYSTEM:(OI)(CI)(F)' 'BUILTIN\Administrators:(OI)(CI)(F)' 'BUILTIN\Users:(OI)(CI)(M)' | Out-Null
}

function Set-SystemHooksPath {
    param([Parameter(Mandatory)][string] $GitExe)

    $value = $HooksDir -replace '\\', '/'
    & $GitExe config --system core.hooksPath $value
    if ($LASTEXITCODE -ne 0) { throw "git config --system core.hooksPath failed with $LASTEXITCODE" }

    $applied = (& $GitExe config --system --get core.hooksPath).Trim()
    Write-Log "System core.hooksPath = $applied"

    # A per-user value silently wins over the system scope. Report it so the
    # SCCM run surfaces the drift even though the hook still installs.
    $userValue = & $GitExe config --global --get core.hooksPath 2>$null
    if ($userValue) {
        Write-Log "A global (per-user) core.hooksPath is set to '$userValue' and overrides the system value for that profile." -Level WARN
    }
}

#endregion

#region main ----------------------------------------------------------------

try {
    Write-Log '--- Install-GitleaksHook starting ---'
    Write-Log "Host: $env:COMPUTERNAME  User: $env:USERNAME  AuditOnly: $($AuditOnly.IsPresent)"

    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        throw 'Running 32-bit on a 64-bit OS. Re-run 64-bit so ProgramFiles resolves correctly.'
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Administrator or SYSTEM rights are required.' }

    $gitExe = Resolve-GitExe
    if (-not $gitExe) {
        throw 'git.exe not found. Deploy Git for Windows first and set it as a dependency of this Application.'
    }
    Write-Log "Using git at $gitExe"

    Install-GitleaksBinary
    Install-Hook
    Set-SystemHooksPath -GitExe $gitExe

    Write-Log 'Secret pre-commit scanning is active for all users on this device.'
    Write-Log '--- Install-GitleaksHook finished (0) ---'
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    Write-Log '--- Install-GitleaksHook failed (1) ---'
    exit 1
}

#endregion
