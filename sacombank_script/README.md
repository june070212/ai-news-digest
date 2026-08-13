# GitHub Copilot enterprise policy package (SCCM / MECM)

Deploys GitHub Copilot and VS Code enterprise policies to managed Windows
clients through Configuration Manager. All settings are device-scoped and
override user and workspace settings on the machine.

| File | Role in SCCM |
| --- | --- |
| `Apply-CopilotPolicy.ps1` | Install program / CI remediation script |
| `Detect-CopilotPolicy.ps1` | Detection method / CI compliance rule |
| `Remove-CopilotPolicy.ps1` | Uninstall program / rollback |

## Configuration channels written

1. `HKLM\SOFTWARE\Policies\Microsoft\VSCode` — VS Code enterprise policies
   (the same values the shipped `vscode.admx` template writes).
2. `HKLM\SOFTWARE\Policies\GitHubCopilot` — Copilot managed settings, native
   MDM channel. Read by both VS Code and GitHub Copilot CLI, and takes
   precedence over the `Microsoft\VSCode` value for the same policy.
3. `%ProgramFiles%\GitHubCopilot\managed-settings.json` — optional file-based
   channel (`-IncludeFileChannel`), lowest precedence. The file must not be
   world-writable, so the script tightens its ACL.

## Policy mapping

| Requested setting | Registry value | Key | Applied value |
| --- | --- | --- | --- |
| `chat.agent.enabled = false` | `ChatAgentMode` | VSCode | `0` (DWORD) |
| `chat.tools.global.autoApprove = false` | `ChatToolsAutoApprove` | VSCode | `0` (DWORD) |
| | `permissions.disableBypassPermissionsMode` | GitHubCopilot | `disable` |
| `chat.mcp.access = registryOnly` | `ChatMCP` | VSCode | `registry` |
| `github.copilot.chat.otel.enabled = true` | `CopilotOtelEnabled` / `telemetry.enabled` | both | `1` / `true` |
| `github.copilot.chat.otel.otlpEndpoint` | `CopilotOtelEndpoint` / `telemetry.endpoint` | both | `-OtlpEndpoint` |
| hardening extras | `ChatAgentExtensionTools`, `ChatToolsTerminalEnableAutoApprove`, `ChatHooks`, `EnableFeedback`, `CopilotOtelCaptureContent`, `allowManagedMcpServersOnly`, `permissions.deny` | both | see script |

Two corrections against the reference list:

- `chat.mcp.access` accepts `all`, `registry`, or `none`. There is no
  `registryOnly`; `registry` is the registry-only value.
- The OTel settings are `chat.agentHost.otel.*`, enforced by the
  `CopilotOtel*` policies or by the `telemetry.*` Copilot managed keys, not by
  `github.copilot.chat.otel.*`.

## Deploy as an SCCM Application

1. Copy this folder to a content source share.
2. Create an Application with a **Script Installer** deployment type.
3. Install program:

   ```
   powershell.exe -ExecutionPolicy Bypass -NoProfile -File ".\Apply-CopilotPolicy.ps1" -OtlpEndpoint "https://otel-collector.contoso.com:4318" -IncludeFileChannel
   ```

4. Uninstall program:

   ```
   powershell.exe -ExecutionPolicy Bypass -NoProfile -File ".\Remove-CopilotPolicy.ps1" -RemoveFileChannel
   ```

5. Detection method: **Custom Script → PowerShell**, paste
   `Detect-CopilotPolicy.ps1`. Compliant when it returns `Installed`.
6. User experience: install for **system**, whether or not a user is signed in.
7. Leave **Run as 32-bit process** unchecked. A 32-bit host would redirect the
   writes to `WOW6432Node`, where VS Code never looks — the scripts fail fast
   in that case rather than reporting a false success.

## Deploy as a Configuration Item (recommended for drift)

Create a CI setting of type **Script**, data type **String**:

- Discovery script: `Detect-CopilotPolicy.ps1`
- Remediation script: `Apply-CopilotPolicy.ps1`
- Compliance rule: value **Equals** `Installed`, remediate when non-compliant.

This re-applies the policy whenever a local admin edits or clears the keys.

## Logging and verification

Both scripts append to `%WinDir%\CCM\Logs\Apply-CopilotPolicy.log`
(CMTrace-readable, falls back to `%WinDir%\Logs` on machines without the CCM
client). Override with `-LogPath`.

On a client, confirm enforcement in VS Code with the command palette:
**Developer: Policy Diagnostics**. The report lists each applied policy, its
source, and the enforced value. Managed settings only load at startup, so
restart VS Code and Copilot CLI after deployment.

## Customising

Edit the `$vsCodePolicies` and `$copilotManagedSettings` tables at the top of
`Apply-CopilotPolicy.ps1`, then mirror any value you want SCCM to enforce into
the `$expected` table in `Detect-CopilotPolicy.ps1` and the removal lists in
`Remove-CopilotPolicy.ps1`.

Useful parameters:

| Parameter | Default | Notes |
| --- | --- | --- |
| `-OtlpEndpoint` | `https://otel-collector.contoso.com:4318` | Replace with your collector |
| `-OtlpProtocol` | `otlp-http` | or `otlp-grpc` |
| `-McpAccess` | `registry` | `all` \| `registry` \| `none` |
| `-ApprovedGitHubOrgs` | none | Gates all AI features behind approved orgs; `*` allows any GitHub account |
| `-IncludeFileChannel` | off | Also write `managed-settings.json` |

## References

- [Centrally manage VS Code settings with policies](https://code.visualstudio.com/docs/enterprise/policies)
- [Manage AI settings in enterprise environments](https://code.visualstudio.com/docs/enterprise/ai-settings)
- [Configure enterprise managed settings](https://docs.github.com/copilot/how-tos/administer-copilot/manage-for-enterprise/manage-agents/configure-enterprise-managed-settings)
