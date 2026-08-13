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
    [string] $McpAccess    = 'registry'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expected = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'; Name = 'ChatAgentMode';                      Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'; Name = 'ChatToolsAutoApprove';               Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'; Name = 'ChatMCP';                            Value = $McpAccess }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'; Name = 'ChatAgentExtensionTools';            Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'; Name = 'ChatToolsTerminalEnableAutoApprove'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'; Name = 'ChatHooks';                          Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'; Name = 'CopilotOtelEnabled';                 Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'; Name = 'CopilotOtelEndpoint';                Value = $OtlpEndpoint }

    @{ Path = 'HKLM:\SOFTWARE\Policies\GitHubCopilot';    Name = 'permissions.disableBypassPermissionsMode'; Value = 'disable' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\GitHubCopilot';    Name = 'telemetry.enabled';                        Value = 'true' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\GitHubCopilot';    Name = 'telemetry.endpoint';                       Value = $OtlpEndpoint }
)

try {
    foreach ($e in $expected) {
        if (-not (Test-Path -LiteralPath $e.Path)) { exit 0 }

        $actual = $null
        try {
            $actual = (Get-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction Stop).($e.Name)
        } catch { exit 0 }

        if ("$actual" -ne "$($e.Value)") { exit 0 }
    }

    Write-Output 'Installed'
    exit 0
}
catch {
    # Any unexpected failure is reported as not detected so SCCM retries.
    exit 0
}
