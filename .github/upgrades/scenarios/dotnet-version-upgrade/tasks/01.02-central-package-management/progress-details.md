# Progress — 01.02-central-package-management

## Result
✅ Complete — 2026-08-07 15:20

## What happened
- Created `Directory.Packages.props` with `ManagePackageVersionsCentrally=true`.
- Pinned `Newtonsoft.Json` to **13.0.3** (was 13.0.3 / 12.0.3 / 11.0.2 across three projects).
- Pinned `System.Data.SqlClient` to 4.8.5 unchanged — its replacement is task 04.01.
- Pinned `xunit` to 2.9.2.
- Stripped `Version=` from 3 SDK-style project files.

## Files changed
- `sample/ContosoOrders/Directory.Packages.props` (created, +14 / -0)
- `sample/ContosoOrders/src/Contoso.Orders.Domain/Contoso.Orders.Domain.csproj` (+1 / -1)
- `sample/ContosoOrders/src/Contoso.Orders.Data/Contoso.Orders.Data.csproj` (+2 / -2)
- `sample/ContosoOrders/tests/Contoso.Orders.Tests/Contoso.Orders.Tests.csproj` (+2 / -2)

## Validation
Build: 0 errors, 12 warnings — unchanged from baseline.

## Notes
`Contoso.Orders.Tests` moved from Newtonsoft.Json 11.0.2 to 13.0.3, a two-major bump. All
47 tests still pass; the serializer settings in `OrderSerializationTests` did not need
changes because they never relied on the pre-12 default `DateTimeZoneHandling`.
