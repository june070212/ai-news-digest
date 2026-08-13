<#
.SYNOPSIS
    Applies GitHub Copilot / VS Code enterprise policies to a Windows client.

.DESCRIPTION
    Designed to run as a Configuration Manager (SCCM/MECM) Application, Package
    program, or Configuration Item remediation script, under the SYSTEM account.

    It writes three managed-configuration surfaces:

      1. HKLM\SOFTWARE\Policies\Microsoft\VSCode
         VS Code enterprise (ADMX-equivalent) policies. Override user and
         workspace settings on the device.

      2. HKLM\SOFTWARE\Policies\GitHubCopilot
         Copilot managed settings delivered through the native MDM channel.
         Shared by VS Code and GitHub Copilot CLI. Highest precedence.

      3. %ProgramFiles%\GitHubCopilot\managed-settings.json  (-IncludeFileChannel)
         File-based channel, for hosts where the registry channel is not read.
         Lowest precedence, so it is safe to ship alongside the other two.

.PARAMETER OtlpEndpoint
    OTLP collector endpoint for Copilot telemetry export.

.PARAMETER OtlpProtocol
    OTLP transport: otlp-http or otlp-grpc.

.PARAMETER McpAccess
    Value for chat.mcp.access: all | registry | none.
    NOTE: the supported value for "registry only" is 'registry'.

.PARAMETER ApprovedGitHubOrgs
    When supplied, all AI features stay disabled until the user signs in to a
    GitHub account in one of these orgs. Use '*' to accept any GitHub account.

.PARAMETER IncludeFileChannel
    Also write %ProgramFiles%\GitHubCopilot\managed-settings.json.

.PARAMETER LogPath
    Log file. Defaults to the CCM logs folder so CMTrace and SCCM client log
    collection pick it up.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Apply-CopilotPolicy.ps1 `
        -OtlpEndpoint "https://otel-collector.contoso.com:4318" -IncludeFileChannel

.NOTES
    Exit codes: 0 = success (no reboot), 1 = failure.
    Must run 64-bit. In the SCCM deployment type leave "Run as 32-bit process"
    unchecked, otherwise the values land under WOW6432Node and are ignored.
#>

[CmdletBinding()]
param(
    [string]   $OtlpEndpoint       = 'https://otel-collector.contoso.com:4318',
    [ValidateSet('otlp-http', 'otlp-grpc')]
    [string]   $OtlpProtocol       = 'otlp-http',
    [ValidateSet('all', 'registry', 'none')]
    [string]   $McpAccess          = 'registry',
    [string]   $ServiceName        = 'vscode-copilot',
    [string[]] $ApprovedGitHubOrgs = @(),
    [switch]   $IncludeFileChannel,
    [string]   $LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$VSCodePolicyKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\VSCode'
$CopilotPolicyKey = 'HKLM:\SOFTWARE\Policies\GitHubCopilot'
$ManagedFilePath  = Join-Path $env:ProgramFiles 'GitHubCopilot\managed-settings.json'

#region logging -------------------------------------------------------------

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
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

#endregion

#region policy definitions --------------------------------------------------

# VS Code enterprise policies -> HKLM\SOFTWARE\Policies\Microsoft\VSCode
# Boolean policies are REG_DWORD (0/1); string and JSON policies are REG_SZ.
#
#   Registry value name                Setting it enforces
#   ---------------------------------- ------------------------------------------
$vsCodePolicies = @(
    # chat.agent.enabled = false -> agent mode cannot be selected in chat
    @{ Name = 'ChatAgentMode';                      Type = 'DWord';  Value = 0 }

    # chat.tools.global.autoApprove = false -> "YOLO mode" / Bypass Approvals hidden
    @{ Name = 'ChatToolsAutoApprove';               Type = 'DWord';  Value = 0 }

    # chat.mcp.access -> only MCP servers from the configured registry may run
    @{ Name = 'ChatMCP';                            Type = 'String'; Value = $McpAccess }

    # chat.extensionTools.enabled = false -> block third-party extension tools
    @{ Name = 'ChatAgentExtensionTools';            Type = 'DWord';  Value = 0 }

    # chat.tools.terminal.enableAutoApprove = false -> no silent terminal commands
    @{ Name = 'ChatToolsTerminalEnableAutoApprove'; Type = 'DWord';  Value = 0 }

    # chat.useHooks = false -> no shell hooks around agent lifecycle events
    @{ Name = 'ChatHooks';                          Type = 'DWord';  Value = 0 }

    # telemetry.feedback.enabled = false -> hide issue reporter and surveys
    @{ Name = 'EnableFeedback';                     Type = 'DWord';  Value = 0 }

    # Copilot OpenTelemetry export -> chat.agentHost.otel.*
    @{ Name = 'CopilotOtelEnabled';                 Type = 'DWord';  Value = 1 }
    @{ Name = 'CopilotOtelEndpoint';                Type = 'String'; Value = $OtlpEndpoint }
    @{ Name = 'CopilotOtelExporterType';            Type = 'String'; Value = $OtlpProtocol }
    @{ Name = 'CopilotOtelCaptureContent';          Type = 'DWord';  Value = 0 }
    @{ Name = 'CopilotOtelServiceName';             Type = 'String'; Value = $ServiceName }
)

if ($ApprovedGitHubOrgs.Count -gt 0) {
    # Gate every AI feature until the user signs in to an approved org.
    $vsCodePolicies += @{
        Name  = 'ChatApprovedAccountOrganizations'
        Type  = 'String'
        Value = (ConvertTo-Json -InputObject @($ApprovedGitHubOrgs) -Compress)
    }
}

# Copilot managed settings -> HKLM\SOFTWARE\Policies\GitHubCopilot
# These win over the Microsoft\VSCode value for the same policy and are also
# read by GitHub Copilot CLI. Scalar keys use their dotted name verbatim;
# structured keys are stored as a JSON string.
$copilotManagedSettings = @(
    @{ Name = 'permissions.disableBypassPermissionsMode'; Type = 'String'; Value = 'disable' }
    @{ Name = 'telemetry.enabled';                        Type = 'String'; Value = 'true' }
    @{ Name = 'telemetry.endpoint';                       Type = 'String'; Value = $OtlpEndpoint }
    @{ Name = 'telemetry.protocol';                       Type = 'String'; Value = $OtlpProtocol }
    @{ Name = 'telemetry.captureContent';                 Type = 'String'; Value = 'false' }
    @{ Name = 'telemetry.lockCaptureContent';             Type = 'String'; Value = 'true' }
    @{ Name = 'telemetry.serviceName';                    Type = 'String'; Value = $ServiceName }
    @{ Name = 'allowManagedMcpServersOnly';               Type = 'String'; Value = 'true' }
    @{
        Name  = 'permissions.deny'
        Type  = 'String'
        Value = (ConvertTo-Json -Compress -InputObject @(
            'Shell(rm -rf *)',
            'Read(~/.ssh/**)',
            'Read(~/.aws/**)',
            'Edit(//etc/**)'
        ))
    }
)

#endregion

#region helpers -------------------------------------------------------------

function Test-Administrator {
    # Isolated so the deployment can be exercised on a test harness where the
    # Windows identity APIs are not available.
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal] $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-PolicyKey {
    param(
        [Parameter(Mandatory)][string]   $Path,
        [Parameter(Mandatory)][object[]] $Values
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
        Write-Log "Created key $Path"
    }

    foreach ($v in $Values) {
        $current = $null
        try {
            $current = (Get-ItemProperty -LiteralPath $Path -Name $v.Name -ErrorAction Stop).($v.Name)
        } catch { }

        if ($null -ne $current -and "$current" -eq "$($v.Value)") {
            Write-Log "  = $($v.Name) already '$($v.Value)'"
            continue
        }

        New-ItemProperty -LiteralPath $Path -Name $v.Name -PropertyType $v.Type `
                         -Value $v.Value -Force | Out-Null
        Write-Log "  + $($v.Name) = '$($v.Value)' ($($v.Type))"
    }
}

function Write-ManagedSettingsFile {
    param([Parameter(Mandatory)][string] $Path)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $payload = [ordered]@{
        permissions = [ordered]@{
            disableBypassPermissionsMode = 'disable'
            deny = @(
                'Shell(rm -rf *)',
                'Read(~/.ssh/**)',
                'Read(~/.aws/**)',
                'Edit(//etc/**)'
            )
        }
        allowManagedMcpServersOnly = $true
        telemetry = [ordered]@{
            enabled            = $true
            endpoint           = $OtlpEndpoint
            protocol           = $OtlpProtocol
            captureContent     = $false
            lockCaptureContent = $true
            serviceName        = $ServiceName
        }
    }

    # Windows PowerShell 5.1 emits a UTF-8 BOM for -Encoding UTF8, and a BOM
    # ahead of "{" breaks strict JSON parsers. Write BOM-less UTF-8 explicitly.
    $json = ConvertTo-Json -InputObject $payload -Depth 6
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
    Write-Log "Wrote managed settings file $Path"

    # The file channel is ignored when the file is world-writable, so drop
    # inheritance and leave write access with SYSTEM and Administrators only.
    & icacls.exe $Path /inheritance:r /grant:r `
        'SYSTEM:(F)' 'BUILTIN\Administrators:(F)' 'BUILTIN\Users:(RX)' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "icacls returned $LASTEXITCODE for $Path" -Level WARN
    }
}

#endregion

#region main ----------------------------------------------------------------

try {
    Write-Log '--- Apply-CopilotPolicy starting ---'
    Write-Log "Host: $env:COMPUTERNAME  User: $env:USERNAME  PS: $($PSVersionTable.PSVersion)"

    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        throw 'Running 32-bit on a 64-bit OS: registry writes would be redirected to WOW6432Node and ignored. Re-run 64-bit (uncheck "Run as 32-bit process" in the SCCM deployment type).'
    }

    $isAdmin = Test-Administrator
    if (-not $isAdmin) {
        throw 'Administrator or SYSTEM rights are required to write HKLM policy keys.'
    }

    Write-Log "Applying VS Code enterprise policies to $VSCodePolicyKey"
    Set-PolicyKey -Path $VSCodePolicyKey -Values $vsCodePolicies

    Write-Log "Applying Copilot managed settings to $CopilotPolicyKey"
    Set-PolicyKey -Path $CopilotPolicyKey -Values $copilotManagedSettings

    if ($IncludeFileChannel) {
        Write-ManagedSettingsFile -Path $ManagedFilePath
    }

    Write-Log 'Policies applied. Users must restart VS Code / Copilot CLI to pick them up.'
    Write-Log '--- Apply-CopilotPolicy finished (0) ---'
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    Write-Log '--- Apply-CopilotPolicy failed (1) ---'
    exit 1
}

#endregion
