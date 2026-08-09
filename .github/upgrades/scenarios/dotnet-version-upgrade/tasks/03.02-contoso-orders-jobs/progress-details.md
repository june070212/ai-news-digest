# Progress — 03.02-contoso-orders-jobs

## Result
🔄 In Progress — started 2026-08-09 09:41

## What happened so far
- Set `<TargetFramework>net8.0</TargetFramework>` and removed the `System.Runtime.Remoting`
  and `System.Configuration` assembly references.
- Restore now fails to resolve 2 assemblies, as predicted by the assessment.
- Build reports **11 errors**:
  - 5 × `RemotingConfiguration` / `Activator.GetObject` in `JobDispatcher.cs`
  - 2 × `ConfigurationManager` in `Program.cs`
  - 4 × `BinaryFormatter` now error-level (`SYSLIB0011` promoted) in `JobPayload.cs`

## Currently blocked on
The 5 remoting errors cannot be fixed inside this task — they need the dispatcher
re-architecture tracked by `05.02-remoting-removal`, which failed its first attempt.
Awaiting a decision on named pipes vs. gRPC before this task can be closed.

## Files changed so far
- `sample/ContosoOrders/src/Contoso.Orders.Jobs/Contoso.Orders.Jobs.csproj` (+2 / -7)

## Next step
Add `System.Configuration.ConfigurationManager` as a temporary compatibility package so the
error surface narrows to remoting only, then hand off to `05.02`.
