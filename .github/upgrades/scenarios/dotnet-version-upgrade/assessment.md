# Assessment — ContosoOrders

**Analyzed**: 2026-08-07 09:14 → 09:21 UTC (6m 47s)
**Target framework**: `net8.0`
**Projects**: 5 · **Incidents**: 23 · **Estimated effort**: 67 story points

## Summary

| Severity | Count |
|----------|-------|
| Mandatory | 15 |
| Potential | 6 |
| Information | 2 |

Three of five projects already target `net8.0`. The upgrade is gated on two legacy
non-SDK projects, `Contoso.Orders.Web` and `Contoso.Orders.Jobs`.

## Per project

| Project | Format | Frameworks | Incidents | Effort |
|---------|--------|-----------|-----------|--------|
| Contoso.Orders.Web | non-SDK | net472 | 21 | 34 |
| Contoso.Orders.Jobs | non-SDK | net472 | 14 | 21 |
| Contoso.Orders.Data | SDK | net8.0 | 6 | 8 |
| Contoso.Orders.Tests | SDK | net8.0 | 2 | 3 |
| Contoso.Orders.Domain | SDK | net8.0 | 1 | 1 |

## Top findings

1. **`System.Web` is not available on .NET 8** (9 incidents, Web).
   `HttpContext.Current`, `System.Web.Mvc`, and `Global.asax` all require an ASP.NET Core
   rewrite. This is the bulk of the 34-point Web estimate.

2. **`System.Runtime.Remoting` was removed** (3 incidents, Jobs).
   No shim exists. `JobDispatcher` must be re-implemented; named pipes are the closest
   behavioural match for the current single-machine deployment.

3. **`ConfigurationManager` is not in the BCL** (2 incidents, Web + Jobs).
   Either add `System.Configuration.ConfigurationManager` as a compatibility package or —
   preferred — migrate to `Microsoft.Extensions.Configuration` and `appsettings.json`.

4. **`Newtonsoft.Json` version drift** (3 versions: 13.0.3, 12.0.3, 11.0.2).
   Resolved in phase 01 by introducing Central Package Management.

5. **`System.Data.SqlClient` is legacy** (Data).
   Replace with `Microsoft.Data.SqlClient` 5.2.2 rather than bumping in place.

6. **`BinaryFormatter`** (Data + Jobs).
   Compiles on .NET 8 but throws at runtime unless explicitly re-enabled, and is gone in
   .NET 9. Flagged as Potential; recommend a follow-up scenario.
