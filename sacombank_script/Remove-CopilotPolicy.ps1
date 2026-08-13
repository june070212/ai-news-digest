<#
.SYNOPSIS
    Removes the GitHub Copilot / VS Code enterprise policies applied by
    Apply-CopilotPolicy.ps1.

.DESCRIPTION
    Use as the Uninstall program of the SCCM Application, or to roll back a bad
    deployment. Removes only the values this package writes; other values under
    the policy keys are left alone, and a key is deleted only when it ends up
    empty.

.PARAMETER RemoveFileChannel
    Also delete %ProgramFiles%\GitHubCopilot\managed-settings.json.

.NOTES
    Exit codes: 0 = success, 1 = failure. Run 64-bit.
#>

[CmdletBinding()]
param(
    [switch] $RemoveFileChannel,
    [string] $LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$VSCodePolicyKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'
$CopilotPolicyKey = 'HKLM:\SOFTWARE\Policies\GitHubCopilot'
$ManagedFilePath  = Join-Path $env:ProgramFiles 'GitHubCopilot\managed-settings.json'

if (-not $LogPath) {
    $ccmLogs = Join-Path $env:WinDir 'CCM\Logs'
    $logDir  = if (Test-Path $ccmLogs) { $ccmLogs } else { Join-Path $env:WinDir 'Logs' }
    $LogPath = Join-Path $logDir 'Apply-CopilotPolicy.log'
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

$vsCodeValues = @(
    'ChatAgentMode', 'ChatToolsAutoApprove', 'ChatMCP', 'ChatAgentExtensionTools',
    'ChatToolsTerminalEnableAutoApprove', 'ChatHooks', 'EnableFeedback',
    'CopilotOtelEnabled', 'CopilotOtelEndpoint', 'CopilotOtelExporterType',
    'CopilotOtelCaptureContent', 'CopilotOtelServiceName',
    'ChatApprovedAccountOrganizations'
)

$copilotValues = @(
    'permissions.disableBypassPermissionsMode', 'permissions.deny',
    'telemetry.enabled', 'telemetry.endpoint', 'telemetry.protocol',
    'telemetry.captureContent', 'telemetry.lockCaptureContent',
    'telemetry.serviceName', 'allowManagedMcpServersOnly'
)

function Remove-PolicyValues {
    param(
        [Parameter(Mandatory)][string]   $Path,
        [Parameter(Mandatory)][string[]] $Names
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Key $Path not present, nothing to remove"
        return
    }

    foreach ($name in $Names) {
        try {
            Remove-ItemProperty -LiteralPath $Path -Name $name -Force -ErrorAction Stop
            Write-Log "  - $name"
        } catch [System.Management.Automation.PSArgumentException] {
            # value already gone
        } catch {
            Write-Log "  ! could not remove $name : $($_.Exception.Message)" -Level WARN
        }
    }

    $key = Get-Item -LiteralPath $Path
    if ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) {
        Remove-Item -LiteralPath $Path -Force
        Write-Log "Removed empty key $Path"
    }
}

try {
    Write-Log '--- Remove-CopilotPolicy starting ---'

    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        throw 'Running 32-bit on a 64-bit OS: the real policy keys would not be touched. Re-run 64-bit.'
    }

    Write-Log "Removing VS Code enterprise policies from $VSCodePolicyKey"
    Remove-PolicyValues -Path $VSCodePolicyKey -Names $vsCodeValues

    Write-Log "Removing Copilot managed settings from $CopilotPolicyKey"
    Remove-PolicyValues -Path $CopilotPolicyKey -Names $copilotValues

    if ($RemoveFileChannel -and (Test-Path -LiteralPath $ManagedFilePath)) {
        Remove-Item -LiteralPath $ManagedFilePath -Force
        Write-Log "Deleted $ManagedFilePath"
    }

    Write-Log '--- Remove-CopilotPolicy finished (0) ---'
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    Write-Log '--- Remove-CopilotPolicy failed (1) ---'
    exit 1
}
