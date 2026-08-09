# 01.01 — Establish green baseline build

Restore and build `sample/ContosoOrders/ContosoOrders.sln` on its current frameworks with
no source changes, so any later failure is attributable to the upgrade rather than to
pre-existing breakage.

**Exit criteria**: `msbuild` returns 0 errors. Warning count is recorded as the baseline.
