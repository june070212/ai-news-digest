# Upgrade Plan — ContosoOrders → .NET 8.0

**Solution**: `sample/ContosoOrders/ContosoOrders.sln`
**Target**: `net8.0`
**Strategy**: Bottom-up
**Generated**: 2026-08-07 09:24 UTC

## Why bottom-up

`Contoso.Orders.Domain` and `Contoso.Orders.Data` already target `net8.0` and sit at the
bottom of the reference graph. The two blockers — `Contoso.Orders.Web` and
`Contoso.Orders.Jobs` — are both leaf consumers, so they can be moved independently
without a big-bang cutover.

```
Domain  <-- Data  <-- Web
                 <-- Jobs
        <-- Tests <-- Data
```

## Phases

| Phase | Goal | Exit criteria |
|-------|------|---------------|
| 01 Preparation | Green baseline + Central Package Management | `dotnet build` succeeds, `Directory.Packages.props` committed |
| 02 SDK-style conversion | Convert Web and Jobs to SDK-style, still on `net472` | Both projects build unchanged |
| 03 Retarget frameworks | Move Web and Jobs to `net8.0` | Projects compile or fail only on known API breaks |
| 04 Dependency remediation | Fix incompatible + drifting packages | No `newVersionNeeded` / `notSupported` packages |
| 05 API remediation | Replace removed APIs | Zero compiler errors |
| 06 Validation | Full build + test | `dotnet build` and `dotnet test` green |

## Known high-risk items

- **`System.Runtime.Remoting` (Jobs)** — removed with no replacement. Requires re-architecting
  the job dispatcher onto named pipes. This is the largest single item in the plan and the
  first attempt failed; it is tracked as `05.02-remoting-removal`.
- **`System.Web` / `System.Web.Mvc` (Web)** — 9 incidents. Migration to ASP.NET Core MVC.
- **`BinaryFormatter` (Jobs, Data)** — disabled by default on .NET 8, removed on .NET 9.
  Not a blocker for this upgrade but should be scheduled immediately after.

## Rollback

Every task commits separately on `nguyenda-microsoft-friendly-winner`. Reverting a single
task is a single `git revert`.
