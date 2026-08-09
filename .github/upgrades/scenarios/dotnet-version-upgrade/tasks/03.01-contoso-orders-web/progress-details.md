# Progress — 03.01-contoso-orders-web

## Result
✅ Complete — 2026-08-09 08:55

## What happened
- `Microsoft.NET.Sdk` → `Microsoft.NET.Sdk.Web`, `net472` → `net8.0`.
- Removed the `System.Web` and `System.Web.Mvc` assembly references (they cannot resolve on net8.0).
- Added `FrameworkReference Microsoft.AspNetCore.App`.
- Build now reports **9 errors**, all of them expected:
  - 4 × `HttpContext.Current` / `System.Web.HttpContext`
  - 3 × `System.Web.Mvc` types (`HttpStatusCodeResult`, `AreaRegistration`, `FilterConfig`)
  - 2 × `ConfigurationManager`
- All 9 mapped: 7 → `05.01`-adjacent ASP.NET Core migration work, 2 → `05.01-configurationmanager`.

## Files changed
- `sample/ContosoOrders/src/Contoso.Orders.Web/Contoso.Orders.Web.csproj` (+4 / -6)

## Validation
Build: 9 errors — all triaged and expected. Solution-wide build is intentionally red until
phase 05 lands.

## Notes
Deliberately did **not** delete `Global.asax.cs` yet. It is dead on ASP.NET Core, but removing
it in the same commit as the retarget would have made the diff hard to review.
