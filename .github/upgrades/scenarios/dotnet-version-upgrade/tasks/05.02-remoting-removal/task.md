# 05.02 — Replace the System.Runtime.Remoting job dispatcher

`Contoso.Orders.Jobs` uses .NET Remoting to expose `JobHost` to a second process on the same
machine. Remoting was removed in .NET Core and has no compatibility shim.

Per the scenario instructions: **do not attempt a shim.** Re-implement the dispatcher on
named pipes, which matches the current single-machine, same-user deployment topology.

**Exit criteria**: no `System.Runtime.Remoting` references remain; the job host starts and
accepts a dispatch from a second process; existing job tests pass.
