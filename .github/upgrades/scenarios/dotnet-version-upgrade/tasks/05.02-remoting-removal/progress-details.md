# Progress — 05.02-remoting-removal

## Result
❌ Failed — 2026-08-09 09:28

## What was attempted
Tried the lowest-risk option first: keep `JobDispatcher`'s public surface identical and swap
only the transport, so callers would not need changes.

1. Searched for a remoting compatibility package. There is none — `System.Runtime.Remoting`
   was removed outright in .NET Core 1.0 and never returned.
2. Attempted a thin `Activator.GetObject`-shaped facade over `NamedPipeClientStream`.
   This failed: the existing code relies on **transparent proxies**, so
   `(JobHost)Activator.GetObject(typeof(JobHost), url)` returns something that behaves like a
   local object across an arbitrary interface. Reproducing that requires either
   `DispatchProxy`-based interception or changing every call site.
3. Prototyped `DispatchProxy`. It works for the 3 synchronous methods but not for
   `JobHost.StreamProgress()`, which returns `IEnumerable<JobProgress>` and is consumed
   lazily across the process boundary. Remoting marshalled this by reference; named pipes
   cannot without an explicit streaming protocol.

## Why it failed
This is not a transport swap — it is an API contract change. `StreamProgress` needs to become
an explicit async stream (`IAsyncEnumerable<JobProgress>`) with a framed pipe protocol, and
its 2 call sites must be updated.

## Files changed
_None — the working tree was reverted after the prototype._

## Recommended next step
Break this task down:
- `05.02.01` — redefine `IJobHost` with `IAsyncEnumerable<JobProgress>`; update both call sites.
- `05.02.02` — implement the named-pipe host and client with a length-framed JSON protocol.
- `05.02.03` — delete `JobDispatcher`'s remoting registration and the `System.Runtime.Remoting` reference.

**Decision needed from the user**: named pipes (recommended — same topology, no new
dependency) vs. gRPC over localhost (more code, but a supported path if the job host ever
moves off-box).
