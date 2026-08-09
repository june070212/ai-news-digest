# 03.02 — Retarget Contoso.Orders.Jobs to net8.0

Flip `TargetFramework` to `net8.0` for the job host. Unlike the Web project, this one has a
hard blocker: `System.Runtime.Remoting` does not exist on .NET 8 at all, so the project will
not even resolve its references until `05.02` lands.

**Exit criteria**: retarget committed; remaining errors triaged; remoting errors explicitly
handed to `05.02-remoting-removal`.
