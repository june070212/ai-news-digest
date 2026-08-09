# Scenario Instructions — .NET Version Upgrade

**Solution**: `sample/ContosoOrders/ContosoOrders.sln`
**Target framework**: `net8.0`
**Strategy**: Bottom-up (leaf projects first, then their dependents)

## Strategy

1. Establish a green baseline build before touching anything.
2. Convert the two legacy non-SDK projects to SDK-style, keeping `net472` so the
   conversion is isolated from the retarget.
3. Retarget converted projects to `net8.0` one at a time.
4. Remediate NuGet dependencies (version drift + incompatible packages).
5. Remediate API breaks surfaced by the compiler.
6. Full solution build + test validation.

## Preferences
- **Pace**: Methodical
- **Flow Mode**: Guided
- **Commit granularity**: One commit per task
- **Test policy**: Existing tests must stay green; no new test frameworks
- **Package sources**: nuget.org only

## Custom Instructions
<!-- Task-specific overrides: "For {taskId}: {instruction}" -->
- For `04.01-system-data-sqlclient`: migrate to `Microsoft.Data.SqlClient`, do **not** pin to a preview version.
- For `05.02-remoting-removal`: `System.Runtime.Remoting` has no .NET 8 equivalent. Replace the cross-process job dispatcher with a named-pipe host rather than attempting a shim.
- For `06-validation`: run `dotnet build` and `dotnet test` for the whole solution, not per project.

## Key Decisions
- 2026-08-07: Adopted Central Package Management (`Directory.Packages.props`) to kill Newtonsoft.Json version drift before retargeting.
- 2026-08-08: Kept `Contoso.Orders.Web` on ASP.NET Core MVC rather than Razor Pages to minimize view rewrites.
- 2026-08-09: Deferred `Contoso.Orders.Jobs` remoting removal to its own task after the first attempt failed.
