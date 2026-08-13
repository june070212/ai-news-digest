# GitHub Copilot enterprise policy package (SCCM / MECM)

Deploys GitHub Copilot and VS Code enterprise policies to managed Windows
clients through Configuration Manager, plus a machine-wide secret-scanning
pre-commit hook. All settings are device-scoped and override user and workspace
settings on the machine.

| File | Role in SCCM |
| --- | --- |
| `Apply-CopilotPolicy.ps1` | Install program / CI remediation script |
| `Detect-CopilotPolicy.ps1` | Detection method / CI compliance rule |
| `Remove-CopilotPolicy.ps1` | Uninstall program / rollback |
| `Install-GitleaksHook.ps1` | Install program for the secret-scanning hook |
| `Detect-GitleaksHook.ps1` | Detection method / CI compliance rule |
| `Remove-GitleaksHook.ps1` | Uninstall program / rollback |

Deploy them as two Applications: policy enforcement and secret scanning are
independent and have different prerequisites (the hook needs Git for Windows).

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

## Block hardcoded secrets at commit time

`Install-GitleaksHook.ps1` deploys client-side secret scanning. The Copilot
policies stop the agent from *reading* credential stores; this stops a
credential that is already in the working tree from reaching a commit.

What it installs:

| Item | Path |
| --- | --- |
| Scanner | `%ProgramFiles%\Gitleaks\gitleaks.exe` |
| Hook | `%ProgramData%\CopilotPolicy\git-hooks\pre-commit` |
| Ruleset | `%ProgramData%\CopilotPolicy\gitleaks.toml` |
| Detections | `%ProgramData%\CopilotPolicy\logs\gitleaks-precommit.log` |
| Wiring | `git config --system core.hooksPath` |

Behaviour on a blocked commit: the scan output is echoed to the developer with
values redacted, the finding is appended to the detection log, and an
Application event log entry is raised under source `GitleaksPreCommit`,
event ID **1001**, for SIEM alerting.

Ship `gitleaks.exe` in the package content next to the script, or pass
`-DownloadIfMissing` to pull it from GitHub Releases at install time.

```
:: Pilot ring - report only, never blocks a commit
powershell.exe -ExecutionPolicy Bypass -NoProfile -File ".\Install-GitleaksHook.ps1" -AuditOnly

:: Production - block commits, and block if the scanner itself is missing
powershell.exe -ExecutionPolicy Bypass -NoProfile -File ".\Install-GitleaksHook.ps1" -FailClosed

:: Uninstall
powershell.exe -ExecutionPolicy Bypass -NoProfile -File ".\Remove-GitleaksHook.ps1"
```

Set Git for Windows as a **dependency** of this deployment type; the install
fails deliberately when `git.exe` is absent.

### Behaviour matrix

| Situation | Default | `-AuditOnly` | `-FailClosed` |
| --- | --- | --- | --- |
| Clean staged diff | commit proceeds | commit proceeds | commit proceeds |
| Secret detected | **blocked** + logged + event 1001 | allowed + logged + event 1001 | **blocked** + logged + event 1001 |
| gitleaks missing or broken | warning, commit proceeds | warning, commit proceeds | **blocked** |
| Repo has its own `.git/hooks/pre-commit` | chained; its non-zero exit still aborts | chained | chained |

That last row matters: `core.hooksPath` normally *replaces* a repository's own
hooks, which would silently break husky, pre-commit, and lefthook setups. The
deployed hook invokes the repository hook itself so existing workflows survive.

### Limits you must plan around

- `git commit --no-verify` skips every hook. Git offers no way to prevent this.
  Treat the endpoint control as defence in depth and keep **GitHub secret
  scanning push protection** as the enforcing gate on the server side.
- A per-user or per-repo `core.hooksPath` overrides the system value. Deploy
  this as a **Configuration Item on a schedule** so drift is re-remediated, and
  watch the install log, which warns when a global override is present.
- Scanning covers the staged diff only. Secrets already in history need
  `gitleaks git` run across the repo, and rotation.
- Tune false positives in `gitleaks.toml`; the file is preserved across
  reinstalls so local allowlist entries are not clobbered.

## Logging and verification

The policy scripts append to `%WinDir%\CCM\Logs\Apply-CopilotPolicy.log` and
the hook scripts to `Install-GitleaksHook.log` in the same folder
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

## Validation status

All six scripts were exercised end-to-end against a simulated Windows client
(emulated `HKLM` hive, Windows environment variables, and stubbed `git.exe`,
`gitleaks.exe`, `icacls.exe`, `eventcreate.exe`), invoked exactly the way SCCM
invokes them. **64 of the 64 cases in `scb_script_scenario.md` that can be
simulated off-box pass.** `PSScriptAnalyzer`'s `PSUseCompatibleSyntax` rule
reports no Windows PowerShell 5.1 incompatibilities - important because SCCM
runs `powershell.exe` (5.1), not `pwsh` 7.

### Defects the simulation caught

These all reproduce only on Windows PowerShell 5.1, so none of them would
surface on a `pwsh` 7 developer machine:

| # | Defect | Impact | Fix |
| --- | --- | --- | --- |
| 1 | `Set-Content -Encoding UTF8` emits a **UTF-8 BOM** on 5.1 | BOM ahead of `{` breaks strict JSON parsers (`managed-settings.json`); BOM on line 1 makes TOML parsers fail, which silently disables `gitleaks.toml` | Write with `[IO.File]::WriteAllText` and `UTF8Encoding($false)` |
| 2 | `& gitleaks.exe version 2>&1` under `$ErrorActionPreference='Stop'` | Real `gitleaks` prints its banner to **stderr**; 5.1 turns those lines into terminating `ErrorRecord`s, so a *working* binary aborted the install | Isolate the call, check `$LASTEXITCODE` explicitly |
| 3 | `${env:ProgramFiles(x86)}` is `$null` on ARM64 hosts | `Join-Path` throws and kills the script while building the search path | Filter roots before joining; also probe `Git\bin\git.exe` |
| 4 | `.Trim()` on possibly-null `git config` output | Throws under `Set-StrictMode` | Null guard, plus assert the value actually persisted |
| 5 | Inline `WindowsIdentity::GetCurrent()` | Admin check was untestable | Extracted to `Test-Administrator` |

### What the simulation does *not* prove

Still requires a pilot VM before broad rollout:

- Real NTFS ACL enforcement by `icacls.exe`
- Real registry behaviour, including 32-bit **WOW6432Node redirection** - run the package 64-bit
- `git config --system` against the real Git for Windows `gitconfig`
- `eventcreate.exe` writing to the Windows Application log
- Downloading `gitleaks.exe` from GitHub Releases through the corporate proxy
- The exact `CopilotOtel*` ADMX value names - confirm against the shipped `vscode.admx`

## References

- [Centrally manage VS Code settings with policies](https://code.visualstudio.com/docs/enterprise/policies)
- [Manage AI settings in enterprise environments](https://code.visualstudio.com/docs/enterprise/ai-settings)
- [Configure enterprise managed settings](https://docs.github.com/copilot/how-tos/administer-copilot/manage-for-enterprise/manage-agents/configure-enterprise-managed-settings)
- [gitleaks](https://github.com/gitleaks/gitleaks)
- [GitHub secret scanning push protection](https://docs.github.com/code-security/secret-scanning/introduction/about-push-protection)
