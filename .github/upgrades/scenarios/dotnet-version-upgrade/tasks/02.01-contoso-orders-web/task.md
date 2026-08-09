# 02.01 — Convert Contoso.Orders.Web to SDK-style

Rewrite the legacy MSBuild project file as SDK-style while **keeping `net472`**. Keeping the
framework fixed isolates format problems from retarget problems.

**Exit criteria**: project builds on `net472` with the same output assembly and 0 new errors.
