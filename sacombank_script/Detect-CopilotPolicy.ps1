<#
.SYNOPSIS
    Detection / compliance rule for the Copilot policy package.

.DESCRIPTION
    Use as:
      * SCCM Application deployment type -> Detection Method -> Custom Script
        (PowerShell). Compliant = writes "Installed" to STDOUT and exits 0.
      * Configuration Item -> Setting of type Script, data type String, with a
        compliance rule of "Equals Installed". Pair it with
        Apply-CopilotPolicy.ps1 as the remediation script.

    Emits nothing and exits 0 when any expected value is missing or wrong, which
    is what SCCM treats as "not detected" / non-compliant.

.NOTES
    Keep the expected values in sync with Apply-CopilotPolicy.ps1.
    Run 64-bit, same as the apply script.
#>

[CmdletBinding()]
param(
    [string] $OtlpEndpoint = 'https://otel-collector.contoso.com:4318',
    [ValidateSet('all', 'registry', 'none')]
    [string] $McpAccess    = 'registry',
    [ValidateSet('all', 'error', 'crash', 'off')]
    [string] $TelemetryLevel = 'off',
    [ValidateSet('none', 'manual', 'start', 'default')]
    [string] $UpdateMode     = 'manual',
    [switch] $AllowThirdPartyAgents,
    [switch] $AllowSessionSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$VS  = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'
$CP  = 'HKLM:\SOFTWARE\Policies\GitHubCopilot'

# Sentinel values only. Optional policies (-AllowedExtensions, network filter,
# private galleries) are deliberately NOT checked here: an admin who deploys
# without them must not see the whole fleet reported non-compliant.
$expected = @(
    @{ Path = $VS; Name = 'ChatAgentMode';                      Value = 0 }
    @{ Path = $VS; Name = 'ChatToolsAutoApprove';               Value = 0 }
    @{ Path = $VS; Name = 'ChatMCP';                            Value = $McpAccess }
    @{ Path = $VS; Name = 'ChatAgentExtensionTools';            Value = 0 }
    @{ Path = $VS; Name = 'ChatToolsTerminalEnableAutoApprove'; Value = 0 }
    @{ Path = $VS; Name = 'ChatHooks';                          Value = 0 }
    @{ Path = $VS; Name = 'CopilotOtelEnabled';                 Value = 1 }
    @{ Path = $VS; Name = 'CopilotOtelEndpoint';                Value = $OtlpEndpoint }
    @{ Path = $VS; Name = 'CopilotOtelProtocol';                Value = $null }

    # Data residency and third-party processors
    @{ Path = $VS; Name = 'CopilotSessionSync';   Value = [int][bool]$AllowSessionSync }
    @{ Path = $VS; Name = 'Claude3PIntegration';  Value = [int][bool]$AllowThirdPartyAgents }
    @{ Path = $VS; Name = 'Codex3PIntegration';   Value = [int][bool]$AllowThirdPartyAgents }

    # Defence in depth behind ChatAgentMode = 0
    @{ Path = $VS; Name = 'ChatAgentSandboxEnabled';                  Value = 'on' }
    @{ Path = $VS; Name = 'ChatAgentSandboxAllowNetwork';             Value = 0 }
    @{ Path = $VS; Name = 'ChatAgentSandboxAllowUnsandboxedCommands'; Value = 0 }
    @{ Path = $VS; Name = 'ChatAllowManagedHooksOnly';                Value = 1 }
    @{ Path = $VS; Name = 'ChatPluginsEnabled';                       Value = 0 }
    @{ Path = $VS; Name = 'BrowserChatTools';                         Value = 0 }
    @{ Path = $VS; Name = 'DictationEnabled';                         Value = 0 }
    @{ Path = $VS; Name = 'ChatToolsEligibleForAutoApproval';         Value = $null }

    # Client and supply-chain management
    @{ Path = $VS; Name = 'TelemetryLevel'; Value = $TelemetryLevel }
    @{ Path = $VS; Name = 'UpdateMode';     Value = $UpdateMode }

    @{ Path = $CP; Name = 'permissions.disableBypassPermissionsMode'; Value = 'disable' }
    @{ Path = $CP; Name = 'telemetry.enabled';                        Value = 'true' }
    @{ Path = $CP; Name = 'telemetry.endpoint';                       Value = $OtlpEndpoint }
    @{ Path = $CP; Name = 'telemetry.lockCaptureContent';             Value = 'true' }
    @{ Path = $CP; Name = 'allowManagedMcpServersOnly';               Value = 'true' }
    @{ Path = $CP; Name = 'permissions.deny';                         Value = $null }
    @{ Path = $CP; Name = 'permissions.ask';                          Value = $null }
)

try {
    foreach ($e in $expected) {
        if (-not (Test-Path -LiteralPath $e.Path)) { exit 0 }

        $actual = $null
        try {
            $actual = (Get-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction Stop).($e.Name)
        } catch { exit 0 }

        # Value = $null means "must exist and be non-empty", used for JSON blobs
        # whose exact text is not worth pinning in a detection rule.
        if ($null -eq $e.Value) {
            if ([string]::IsNullOrWhiteSpace("$actual")) { exit 0 }
        }
        elseif ("$actual" -ne "$($e.Value)") { exit 0 }
    }

    Write-Output 'Installed'
    exit 0
}
catch {
    # Any unexpected failure is reported as not detected so SCCM retries.
    exit 0
}
