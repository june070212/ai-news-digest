# Test scenarios — Copilot policy + secret-scanning package

Validation plan for the two SCCM packages in this folder. Run rings in order:
**Lab VM → IT pilot ring → developer pilot ring → production**.

Legend for expected result: **PASS** = observed behaviour matches, **BLOCK** =
the action is prevented, **ALLOW** = the action proceeds.

---

## Execution sequence

Six scripts, run in a fixed order. Every one needs an **elevated 64-bit**
`powershell.exe` (SCCM: *Run as 32-bit process* **unchecked**, *Run with
administrative rights* **checked**, install behaviour **Install for system**).

```
Package 1 — Copilot policy          Package 2 — Secret scanning
  1. Apply-CopilotPolicy.ps1          4. Install-GitleaksHook.ps1
  2. Detect-CopilotPolicy.ps1         5. Detect-GitleaksHook.ps1
  3. Remove-CopilotPolicy.ps1         6. Remove-GitleaksHook.ps1
     (uninstall only)                    (uninstall only)
```

Order matters in exactly two places: **install Git for Windows before step 4**
(make it an SCCM dependency), and **run step 4 before step 5** — detection is
meaningless until the binary and hook exist. Package 1 and Package 2 are
otherwise independent and may deploy in parallel.

### Step 1 — Apply the Copilot policy  *(SCCM: Install program)*

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Apply-CopilotPolicy.ps1" `
  -OtlpEndpoint "https://otel.sacombank.local:4318" `
  -OtlpProtocol otlp-http `
  -McpAccess registry `
  -ServiceName "vscode-copilot" `
  -ApprovedGitHubOrgs "sacombank" `
  -IncludeFileChannel
```

| Parameter | Default | Notes |
| --- | --- | --- |
| `-OtlpEndpoint` | `https://otel-collector.contoso.com:4318` | **Change this** to your collector |
| `-OtlpProtocol` | `otlp-http` | or `otlp-grpc` |
| `-McpAccess` | `registry` | `all` \| `registry` \| `none` |
| `-ServiceName` | `vscode-copilot` | OTel `service.name` attribute |
| `-ApprovedGitHubOrgs` | none | Gates AI features behind approved orgs |
| `-IncludeFileChannel` | off | Also write `managed-settings.json` (covers Copilot CLI) |
| `-LogPath` | CCM logs | Override only for manual troubleshooting |

Exit **0** = applied. Exit **1** = failed; read the log. Idempotent — safe to
re-run on every SCCM evaluation cycle (case A5).

### Step 2 — Detect compliance  *(SCCM: Detection method → Custom script)*

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Detect-CopilotPolicy.ps1" `
  -OtlpEndpoint "https://otel.sacombank.local:4318" -McpAccess registry
```

The arguments **must match step 1** or the device reports non-compliant
forever. Follows the SCCM contract: prints `Installed` and exits 0 when
compliant, prints **nothing** and exits 0 when not — never exit non-zero, or
SCCM treats it as a script error instead of a remediation trigger (cases D1/D2).

### Step 3 — Remove the policy  *(SCCM: Uninstall program)*

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Remove-CopilotPolicy.ps1" -RemoveFileChannel
```

Pass `-RemoveFileChannel` only if step 1 used `-IncludeFileChannel`. Safe to
re-run (case F6).

### Step 4 — Install the gitleaks hook  *(SCCM: Install program)*

Requires **Git for Windows already installed** — declare it as a dependency.
Stage `gitleaks.exe` next to the scripts in the package source.

```powershell
# Pilot ring — detect and log, but let the commit through
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install-GitleaksHook.ps1" `
  -GitleaksSource ".\gitleaks.exe" -AuditOnly

# Production ring — block the commit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install-GitleaksHook.ps1" `
  -GitleaksSource ".\gitleaks.exe"
```

| Parameter | Default | Notes |
| --- | --- | --- |
| `-GitleaksSource` | none | Path to a staged `gitleaks.exe`. **Preferred** — no internet needed |
| `-DownloadIfMissing` | off | Pull from GitHub Releases instead. Needs proxy access; avoid on locked-down fleets |
| `-Version` | `8.28.0` | Only used with `-DownloadIfMissing` |
| `-AuditOnly` | off | Log the detection, **allow** the commit. Use for the whole pilot ring |
| `-FailClosed` | off | Block the commit if the scanner is missing/broken. Enable **only** after E2 shows the binary is stable |
| `-NoEventLog` | off | Suppress the Application-log event. Leave off so SIEM keeps receiving alerts |
| `-LogPath` | CCM logs | Manual troubleshooting only |

Writes the hook, a baseline `gitleaks.toml`, and sets system-wide
`core.hooksPath`. Exit **1** if Git or the binary is missing (cases K1/K2).

### Step 5 — Detect the hook  *(SCCM: Detection method → Custom script)*

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Detect-GitleaksHook.ps1"
```

No parameters. Verifies the binary, the hook file, **and** that `core.hooksPath`
still points at the managed directory — so a developer who repoints it is
reported non-compliant and auto-remediated on the next cycle (case D-series).

### Step 6 — Remove the hook  *(SCCM: Uninstall program)*

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Remove-GitleaksHook.ps1" -KeepDetectionLog
```

Clears `core.hooksPath` **only if it still points at our directory**, so a
team's own hooks survive. `-KeepDetectionLog` preserves the audit trail for
forensics — recommended in a bank.

### Verifying a run by hand

```powershell
# 1. Policy landed in the 64-bit hive
reg query "HKLM\SOFTWARE\Policies\Microsoft\VSCode" /s

# 2. Both detection scripts report compliant
.\Detect-CopilotPolicy.ps1 -OtlpEndpoint "https://otel.sacombank.local:4318"
.\Detect-GitleaksHook.ps1

# 3. Hook is wired up machine-wide
git config --system --get core.hooksPath

# 4. Live block test (case H2) — expect the commit to be REJECTED
git init C:\Temp\hooktest; cd C:\Temp\hooktest
'aws_secret_access_key = "AKIAIOSFODNN7EXAMPLE"' | Out-File secrets.txt
git add .; git commit -m "test"

# 5. Read the logs
notepad "$env:WinDir\CCM\Logs\CopilotPolicy.log"
notepad "$env:ProgramData\CopilotPolicy\logs\detections.log"
```

In VS Code, confirm enforcement with **`Developer: Policy Diagnostics`** from
the command palette — managed settings show a *Managed by organization* badge.

---

## A. Pre-flight / environment

| # | Scenario | How to test | Expected |
| --- | --- | --- | --- |
| A1 | Script runs 64-bit | Deployment type with *Run as 32-bit process* **unchecked** | Applies. If checked, script aborts with an explicit error rather than writing to `WOW6432Node` |
| A2 | Runs as SYSTEM | Deploy to *device* collection, not user | Applies without a logged-on user |
| A3 | Non-admin execution | Run the apply script as a standard user | Fails fast with "administrator required" |
| A4 | No CCM client present | Run manually on a non-managed VM | Works; log falls back to `%WinDir%\Logs` |
| A5 | Re-run / idempotency | Run apply twice | Second run reports no changes, exit 0, no duplicate values |
| A6 | Git not installed | Run `Install-GitleaksHook.ps1` on a box without Git | Fails deliberately; SCCM reports failure. Set Git for Windows as a **dependency** |

---

## B. Copilot policy enforcement (per-setting)

Verify each on the client with **`Developer: Policy Diagnostics`** in the VS Code
command palette, and by attempting the user action.

| # | Policy | User action to attempt | Expected |
| --- | --- | --- | --- |
| B1 | `chat.agent.enabled = false` | Open Copilot Chat, try to switch to **Agent** mode | Mode unavailable / greyed out — **BLOCK** |
| B2 | Setting override attempt | User sets `chat.agent.enabled: true` in their own `settings.json` | Ignored; policy wins. Setting shows as managed |
| B3 | Workspace override attempt | Add the same key to `.vscode/settings.json` in a repo | Ignored; policy wins |
| B4 | `chat.tools.global.autoApprove = false` | Ask Copilot to run a shell command | Tool call requires explicit per-call approval — **BLOCK** on silent execution |
| B5 | `chat.mcp.access = registry` | Add an arbitrary MCP server to `mcp.json` | Only registry-approved servers load — **BLOCK** on the ad-hoc server |
| B6 | `allowManagedMcpServersOnly` | Same as B5 for Copilot CLI | CLI honours the same restriction |
| B7 | `ChatAgentExtensionTools` | Install a marketplace extension that contributes chat tools | Tools not surfaced to the agent |
| B8 | `ChatToolsTerminalEnableAutoApprove` | Ask for a terminal command | No auto-run of terminal commands |
| B9 | `ChatHooks` | Place a hook config in a repo | Hooks do not execute |
| B10 | `permissions.disableBypassPermissionsMode` | Try to launch Copilot CLI in bypass/YOLO permissions mode | Refused — **BLOCK** |
| B11 | `permissions.deny` on `~/.ssh/**` | Ask Copilot to read `~/.ssh/id_rsa` | Access denied — **BLOCK** |
| B12 | `permissions.deny` on `~/.aws/**` | Ask Copilot to read `~/.aws/credentials` | Access denied — **BLOCK** |
| B13 | `ChatApprovedAccountOrganizations` | Sign in with a personal GitHub account | Sign-in rejected unless in an approved org — **BLOCK** |
| B14 | `EnableFeedback` | Look for the feedback / survey affordance | Hidden |

### B-OTel — audit telemetry

| # | Scenario | How to test | Expected |
| --- | --- | --- | --- |
| B15 | Telemetry reaches the collector | Run a Copilot Chat prompt with the OTLP endpoint reachable | Span arrives at the configured endpoint with `service.name` |
| B16 | `captureContent = false` | Inspect the emitted span | Metadata only; **no prompt or response text** |
| B17 | `lockCaptureContent = true` | User sets `captureContent: true` in their settings | Override ignored — **BLOCK** |
| B18 | Collector unreachable | Block the OTLP endpoint at the firewall | Copilot still functions; no user-visible failure |
| B19 | Wrong protocol | Set `-OtlpProtocol` to a value the collector doesn't speak | No spans; confirms protocol must match the collector |

### B-Precedence

| # | Scenario | Expected |
| --- | --- | --- |
| B20 | Copilot managed setting + equivalent VS Code ADMX policy both set | Managed setting **replaces** the ADMX value (does not merge) |
| B21 | `-IncludeFileChannel` used alongside registry | Registry (native MDM) wins over `managed-settings.json` |
| B22 | `managed-settings.json` made world-writable | File is **ignored** by design — confirm the ACL the script sets is intact |

---

## C. Detection & compliance (Copilot policy)

| # | Scenario | Expected |
| --- | --- | --- |
| C1 | Fully applied machine | `Detect-CopilotPolicy.ps1` emits `Installed`, exit 0 |
| C2 | Never applied | Emits nothing, exit 0 → SCCM reports *not detected* |
| C3 | Drift: user/admin deletes one registry value | Detection returns non-compliant; CI remediation re-applies |
| C4 | Drift: value changed to a wrong value | Same as C3 |
| C5 | Detection script throws | Exits 0 so SCCM retries rather than hard-failing |
| C6 | After `Remove-CopilotPolicy.ps1` | Not detected; policy keys removed; VS Code settings return to user control |
| C7 | Removal is surgical | Only the values this package wrote are deleted; a key is removed only when it ends up empty |

---

## D. Secret scanning — pre-commit hook

Setup: a scratch repo on the client, one file containing a realistic-looking
key (for example an AWS-style `AKIA...` string).

| # | Scenario | Expected |
| --- | --- | --- |
| D1 | Clean staged diff | Commit succeeds — **ALLOW** |
| D2 | Staged file contains a secret | Commit rejected, exit 1 — **BLOCK** |
| D3 | Finding is redacted | Terminal output shows the rule and file, **not** the secret value |
| D4 | Detection log written | Entry appended to `%ProgramData%\CopilotPolicy\logs\gitleaks-precommit.log` |
| D5 | Event log alert | Application event **ID 1001**, source `GitleaksPreCommit`, level Warning |
| D6 | SIEM ingestion | Same event forwarded and alertable in the SIEM |
| D7 | `-AuditOnly` mode | Commit **ALLOWED**, but log + event 1001 still raised |
| D8 | `-NoEventLog` | No Application event raised; log file still written |
| D9 | Unstaged secret | Not flagged — scanning covers the **staged diff only**; confirms scope |
| D10 | Secret already in history | Not flagged by the hook; requires a full `gitleaks git` sweep + rotation |
| D11 | Large commit | Hook completes without an unacceptable delay; note the timing |

### D-Interoperability

| # | Scenario | Expected |
| --- | --- | --- |
| D12 | Repo has its own `.git/hooks/pre-commit` (husky / pre-commit / lefthook) | Repo hook still runs — `core.hooksPath` would normally shadow it |
| D13 | Repo hook exits non-zero | Commit still aborts; the repo hook's veto is honoured |
| D14 | Repo hook exits zero, secret present | Commit **BLOCKED** by gitleaks |
| D15 | No repo hook, clean diff | Commit succeeds; no re-entry loop |
| D16 | Commit from VS Code / GitHub Desktop / IDE GUI | Hook fires the same as CLI |
| D17 | Commit from WSL | Note behaviour — WSL uses its own Git and is **not** covered by the Windows system gitconfig |

### D-Failure & bypass modes

| # | Scenario | Expected |
| --- | --- | --- |
| D18 | `gitleaks.exe` deleted, default mode | Warning printed, commit **ALLOWED** (fail-open) |
| D19 | `gitleaks.exe` deleted, `-FailClosed` | Commit **BLOCKED** with a "contact IT Support" message |
| D20 | `-FailClosed` + working binary + clean diff | Commit **ALLOWED** (confirms no false blocking) |
| D21 | `git commit --no-verify` | Commit **succeeds** — known, unavoidable Git limitation. Confirms why push protection is required server-side |
| D22 | User sets a personal `core.hooksPath` (`--global`) | Overrides system scope → hook bypassed. Detection must catch this |
| D23 | Repo sets `core.hooksPath` locally | Same as D22 |
| D24 | Standard user tries to delete or edit the hook / binary | Denied by ACL (read+execute only for Users) |
| D25 | Mixed gitleaks versions (pre- and post-8.19) | Hook picks `git --staged` or legacy `protect --staged` automatically |
| D26 | False positive on a test fixture | Add an allowlist entry to `gitleaks.toml`; reinstall preserves it |

---

## E. Detection & compliance (secret scanning)

| # | Scenario | Expected |
| --- | --- | --- |
| E1 | Correctly installed | `Detect-GitleaksHook.ps1` emits `Installed`, exit 0 |
| E2 | Binary missing | Not detected → SCCM reinstalls |
| E3 | Hook file missing or tampered with (marker comment gone) | Not detected → reinstalled |
| E4 | System `core.hooksPath` unset or repointed | Not detected → reinstalled |
| E5 | Global override present at install time | Install log records a **warning** |
| E6 | Scheduled CI baseline | Drift from D22/D23 surfaces as non-compliant within the eval cycle |
| E7 | `Remove-GitleaksHook.ps1` | `core.hooksPath` unset **only if** it still points at the managed directory |
| E8 | Removal with a third-party `core.hooksPath` in place | That value is left untouched |
| E9 | `-KeepDetectionLog` | Detection log preserved for forensics after uninstall |

---

## F. End-to-end / regression

| # | Scenario | Expected |
| --- | --- | --- |
| F1 | Clean OS build → both packages → reboot | All policies active after restart (VS Code reads policy at startup) |
| F2 | VS Code upgraded to a newer build | Policies still enforced; re-run Policy Diagnostics |
| F3 | Copilot extension updated | Managed settings still honoured |
| F4 | VS Code not yet installed at deployment time | Registry policies applied anyway; enforced when VS Code is later installed |
| F5 | Portable / user-scope VS Code install | **Known gap** — confirm behaviour; policy still applies via HKLM, but personal installs of other IDEs do not |
| F6 | JetBrains / Visual Studio / github.com web | **Out of scope** for this package — verify covered by other controls |
| F7 | Both packages uninstalled | Machine returns to baseline; no orphaned registry values, files, or gitconfig entries |
| F8 | Full developer day-in-the-life | Clone, branch, code with Copilot, commit, push. No unexpected friction beyond the intended blocks |

---

## Recommended rollout gates

1. **Lab** — A1–A6, C1–C7, E1–E9 must all pass.
2. **IT pilot (5–10 devices)** — full B section; confirm OTel spans land in the collector.
3. **Developer pilot** — deploy the hook with `-AuditOnly`. Review the detection
   log for a week and tune `gitleaks.toml` until false positives are near zero.
4. **Production** — switch to blocking mode. Consider `-FailClosed` only after
   the binary's presence is proven stable by E2 compliance reporting.
5. **Always on** — GitHub secret scanning **push protection** stays enabled
   server-side; D21 proves the endpoint hook alone is not sufficient.
