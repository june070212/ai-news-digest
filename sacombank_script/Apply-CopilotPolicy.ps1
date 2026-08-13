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

.PARAMETER TelemetryLevel
    Microsoft (VS Code product) telemetry level: all | error | crash | off.
    Separate from the Copilot OTel export, which stays on so the bank keeps its
    own audit trail.

.PARAMETER UpdateMode
    VS Code auto-update behaviour. Use 'manual' or 'none' on an SCCM-managed
    fleet so the client does not self-update outside the change window.

.PARAMETER ExtensionUpdateDelayHours
    Hold back extension auto-updates by N hours. Blunts marketplace
    supply-chain attacks by letting a malicious release be pulled before it
    reaches the fleet. 0 disables the delay.

.PARAMETER AllowedExtensions
    JSON object for extensions.allowed, e.g.
      '{"microsoft":true,"github":true,"ms-python.python":true,"*":false}'
    OPT-IN: fleet-breaking if the allowlist is wrong. Pilot it first.

.PARAMETER ExtensionGalleryUrl
    Private extension marketplace URL. Leave empty to use the public one.

.PARAMETER McpGalleryUrl
    Private MCP registry URL. Strongly recommended whenever -McpAccess is
    'registry', otherwise "registry" still means the PUBLIC GitHub MCP registry.

.PARAMETER AllowedMcpServers
    JSON array of allowed MCP servers, e.g.
      '[{"serverName":"sacombank-tools"},{"serverUrl":"https://mcp.sacombank.local/*"}]'

.PARAMETER DeniedMcpServers
    JSON array of denied MCP servers. Deny always beats allow.

.PARAMETER EnableNetworkFilter
    OPT-IN. Turns on deny-by-default network filtering for agent tools (fetch
    tool, integrated browser, sandboxed terminal). Only -AllowedNetworkDomains
    can then be reached.

.PARAMETER AllowedNetworkDomains
    Domain allowlist used with -EnableNetworkFilter. Wildcards supported.

.PARAMETER DeniedNetworkDomains
    Domain denylist. Takes precedence over the allowlist.

.PARAMETER DefaultChatModel
    Pin new conversations to an approved model: 'auto', a family name, or a
    full model id. Users can still switch mid-conversation.

.PARAMETER OtlpHeaders
    JSON object of OTLP exporter headers, for collector authentication, e.g.
      '{"Authorization":"Bearer <token>"}'
    Anything written here is readable by any local admin - prefer mTLS or a
    collector that authenticates by device identity.

.PARAMETER OtlpResourceAttributes
    JSON object of extra OTel resource attributes, e.g.
      '{"deployment.environment":"prod","bank.unit":"retail"}'

.PARAMETER AllowThirdPartyAgents
    Re-enables the Anthropic Claude and OpenAI Codex agent integrations. They
    are DISABLED by default because prompts and code leave through a
    non-GitHub processor.

.PARAMETER AllowSessionSync
    Re-enables Copilot session-history sync to GitHub.com. Disabled by default
    so session content stays on the device.

.PARAMETER StrictPluginOnlyCustomization
    OPT-IN and very strict: blocks standalone user/workspace skills, agents,
    hooks, instructions and MCP servers, keeping only policy-approved plugins.

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

    # --- hardening baseline (applied unless overridden) ---
    [ValidateSet('all', 'error', 'crash', 'off')]
    [string]   $TelemetryLevel     = 'off',
    [ValidateSet('none', 'manual', 'start', 'default')]
    [string]   $UpdateMode         = 'manual',
    [int]      $ExtensionUpdateDelayHours = 168,
    [switch]   $AllowThirdPartyAgents,
    [switch]   $AllowSessionSync,

    # --- opt-in, pilot before fleet-wide rollout ---
    [string]   $AllowedExtensions,
    [string]   $ExtensionGalleryUrl,
    [string]   $McpGalleryUrl,
    [string]   $AllowedMcpServers,
    [string]   $DeniedMcpServers,
    [switch]   $EnableNetworkFilter,
    [string[]] $AllowedNetworkDomains = @(),
    [string[]] $DeniedNetworkDomains  = @(),
    [string]   $DefaultChatModel,
    [string]   $OtlpHeaders,
    [string]   $OtlpResourceAttributes,
    [switch]   $StrictPluginOnlyCustomization,

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

# Fine-grained agent permissions, shared by the registry and file channels so
# the two never drift. Order of evaluation is deny > ask > allow > default-ask.
#
# Path prefixes: /=workspace root, ./=cwd, ~/=user home, //=filesystem root.
$DenyRules = @(
    # Destructive shell
    'Shell(rm -rf *)',
    'Shell(format *)',
    'Shell(reg delete *)',
    # Credential and key material the agent must never read
    'Read(~/.ssh/**)',
    'Read(~/.aws/**)',
    'Read(~/.azure/**)',
    'Read(~/.kube/**)',
    'Read(~/.gnupg/**)',
    'Read(~/.docker/config.json)',
    'Read(~/AppData/Roaming/gcloud/**)',
    'Read(**/.env)',
    'Read(**/.env.*)',
    'Read(**/*.pem)',
    'Read(**/*.pfx)',
    'Read(**/*.p12)',
    'Read(**/id_rsa*)',
    'Read(**/id_ed25519*)',
    'Read(**/appsettings.Production.json)',
    # Same paths for writes, so secrets cannot be planted or rewritten either
    'Edit(~/.ssh/**)',
    'Edit(~/.aws/**)',
    'Edit(~/.azure/**)',
    'Edit(//etc/**)',
    'Edit(//Windows/**)',
    # Public paste/exfiltration destinations
    'Domain(pastebin.com)',
    'Domain(*.ngrok.io)',
    'Domain(transfer.sh)'
)

# Require a human decision every time - cannot be auto-approved or bypassed.
$AskRules = @(
    'Shell(git push *)',
    'Shell(git remote *)',
    'Shell(npm publish *)',
    'Shell(curl *)',
    'Shell(Invoke-WebRequest *)',
    'Shell(Invoke-RestMethod *)'
)

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
    # NOTE: the policy is CopilotOtelProtocol (maps to ...otel.exporterType).
    # "CopilotOtelExporterType" is NOT a registered policy name - a value
    # written under that name is silently ignored and shows up under
    # "Non-applied Policy" in Developer: Policy Diagnostics.
    @{ Name = 'CopilotOtelEnabled';                 Type = 'DWord';  Value = 1 }
    @{ Name = 'CopilotOtelEndpoint';                Type = 'String'; Value = $OtlpEndpoint }
    @{ Name = 'CopilotOtelProtocol';                Type = 'String'; Value = $OtlpProtocol }
    @{ Name = 'CopilotOtelCaptureContent';          Type = 'DWord';  Value = 0 }
    @{ Name = 'CopilotOtelServiceName';             Type = 'String'; Value = $ServiceName }

    # --- data residency / third-party processors ----------------------------

    # chat.sessionSync.enabled = false -> session history stays on the device
    # instead of syncing to GitHub.com.
    @{ Name = 'CopilotSessionSync'
       Type = 'DWord'; Value = [int][bool]$AllowSessionSync }

    # Claude / Codex agent sessions route prompts and code through Anthropic and
    # OpenAI. Off unless the bank has cleared those processors.
    @{ Name = 'Claude3PIntegration'
       Type = 'DWord'; Value = [int][bool]$AllowThirdPartyAgents }
    @{ Name = 'Codex3PIntegration'
       Type = 'DWord'; Value = [int][bool]$AllowThirdPartyAgents }

    # --- defence in depth behind ChatAgentMode = 0 --------------------------
    # Agent mode is already off, but these stay set so a future policy change,
    # a policy-refresh gap, or a pilot exception cannot silently open a hole.

    # chat.agent.sandbox.* -> OS-level isolation for anything the agent runs
    @{ Name = 'ChatAgentSandboxEnabled';                 Type = 'String'; Value = 'on' }
    @{ Name = 'ChatAgentSandboxAllowNetwork';            Type = 'DWord';  Value = 0 }
    @{ Name = 'ChatAgentSandboxAllowUnsandboxedCommands'; Type = 'DWord'; Value = 0 }
    @{ Name = 'ChatAgentSandboxAllowAutoApprove';        Type = 'DWord';  Value = 0 }

    # Only hooks from enterprise-managed sources, on top of ChatHooks = 0
    @{ Name = 'ChatAllowManagedHooksOnly';          Type = 'DWord';  Value = 1 }

    # chat.plugins.enabled = false -> no agent plugin marketplaces at all
    @{ Name = 'ChatPluginsEnabled';                 Type = 'DWord';  Value = 0 }

    # Never auto-approve the tools that reach the shell, the network, or tasks
    @{
        Name  = 'ChatToolsEligibleForAutoApproval'
        Type  = 'String'
        Value = (ConvertTo-Json -Compress -InputObject ([ordered]@{
            runInTerminal = $false
            runTask       = $false
            fetch         = $false
        }))
    }

    # workbench.browser.enableChatTools = false -> agent cannot drive the
    # Integrated Browser (a data-exfiltration path that bypasses the proxy).
    @{ Name = 'BrowserChatTools';                   Type = 'DWord';  Value = 0 }

    # dictation.enabled = false -> no microphone capture in chat/editor/terminal
    @{ Name = 'DictationEnabled';                   Type = 'DWord';  Value = 0 }

    # --- client and supply-chain management ---------------------------------

    # telemetry.telemetryLevel -> Microsoft product telemetry (separate from the
    # bank's own OTel export configured above, which stays on).
    @{ Name = 'TelemetryLevel';                     Type = 'String'; Value = $TelemetryLevel }

    # update.mode -> SCCM owns the update cadence, not the client
    @{ Name = 'UpdateMode';                         Type = 'String'; Value = $UpdateMode }
)

if ($ExtensionUpdateDelayHours -gt 0) {
    # Hold extension auto-updates back so a compromised marketplace release can
    # be pulled before it lands on the fleet.
    $vsCodePolicies += @{
        Name = 'ExtensionsAutoUpdateDelay'; Type = 'DWord'; Value = $ExtensionUpdateDelayHours
    }
}

# --- optional policies: only written when the admin supplies a value --------

if ($AllowedExtensions)    { $vsCodePolicies += @{ Name = 'AllowedExtensions';           Type = 'String'; Value = $AllowedExtensions } }
if ($ExtensionGalleryUrl)  { $vsCodePolicies += @{ Name = 'ExtensionGalleryServiceUrl';  Type = 'String'; Value = $ExtensionGalleryUrl } }
if ($McpGalleryUrl)        { $vsCodePolicies += @{ Name = 'McpGalleryServiceUrl';        Type = 'String'; Value = $McpGalleryUrl } }
if ($AllowedMcpServers)    { $vsCodePolicies += @{ Name = 'ChatAllowedMcpServers';       Type = 'String'; Value = $AllowedMcpServers } }
if ($DeniedMcpServers)     { $vsCodePolicies += @{ Name = 'ChatDeniedMcpServers';        Type = 'String'; Value = $DeniedMcpServers } }
if ($DefaultChatModel)     { $vsCodePolicies += @{ Name = 'ChatDefaultModel';            Type = 'String'; Value = $DefaultChatModel } }
if ($OtlpHeaders)          { $vsCodePolicies += @{ Name = 'CopilotOtelHeaders';          Type = 'String'; Value = $OtlpHeaders } }
if ($OtlpResourceAttributes) { $vsCodePolicies += @{ Name = 'CopilotOtelResourceAttributes'; Type = 'String'; Value = $OtlpResourceAttributes } }

if ($StrictPluginOnlyCustomization) {
    $vsCodePolicies += @{ Name = 'ChatStrictPluginOnlyCustomization'; Type = 'DWord'; Value = 1 }
}

if ($EnableNetworkFilter) {
    # Deny by default: with the filter on and an empty allowlist, every domain
    # is blocked for the fetch tool, the browser and sandboxed commands.
    $vsCodePolicies += @{ Name = 'ChatAgentNetworkFilter'; Type = 'DWord'; Value = 1 }
    $vsCodePolicies += @{
        Name = 'ChatAgentAllowedNetworkDomains'
        Type = 'String'; Value = (ConvertTo-Json -Compress -InputObject @($AllowedNetworkDomains))
    }
    if ($DeniedNetworkDomains.Count -gt 0) {
        $vsCodePolicies += @{
            Name = 'ChatAgentDeniedNetworkDomains'
            Type = 'String'; Value = (ConvertTo-Json -Compress -InputObject @($DeniedNetworkDomains))
        }
    }
}

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
        Value = (ConvertTo-Json -Compress -InputObject $DenyRules)
    }
    @{
        Name  = 'permissions.ask'
        Type  = 'String'
        Value = (ConvertTo-Json -Compress -InputObject $AskRules)
    }
)

if ($DefaultChatModel)  { $copilotManagedSettings += @{ Name = 'model';                     Type = 'String'; Value = $DefaultChatModel } }
if ($AllowedMcpServers) { $copilotManagedSettings += @{ Name = 'allowedMcpServers';         Type = 'String'; Value = $AllowedMcpServers } }
if ($DeniedMcpServers)  { $copilotManagedSettings += @{ Name = 'deniedMcpServers';          Type = 'String'; Value = $DeniedMcpServers } }
if ($StrictPluginOnlyCustomization) {
    $copilotManagedSettings += @{ Name = 'strictKnownMarketplaces'; Type = 'String'; Value = 'true' }
}

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
            deny = $DenyRules
            ask  = $AskRules
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

    if ($DefaultChatModel)  { $payload['model'] = $DefaultChatModel }
    if ($AllowedMcpServers) { $payload['allowedMcpServers'] = (ConvertFrom-Json $AllowedMcpServers) }
    if ($DeniedMcpServers)  { $payload['deniedMcpServers']  = (ConvertFrom-Json $DeniedMcpServers) }
    if ($StrictPluginOnlyCustomization) { $payload['strictKnownMarketplaces'] = $true }

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
