# 03.01 — Retarget Contoso.Orders.Web to net8.0

Flip `TargetFramework` to `net8.0` and switch the project SDK to `Microsoft.NET.Sdk.Web`.
API breakage is expected and is **not** fixed here — it is triaged into phase 05.

**Exit criteria**: retarget committed; every remaining compiler error is mapped to a phase-05
task; no unexplained errors.
