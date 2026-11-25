# ContosoOrders (simulation fixture)

This is **not** a real application. It is a synthetic .NET solution used to
demonstrate the Upgrade Agent dashboard end to end: it gives the Projects,
Assessment, and Dependency panels real `.csproj` files to read.

Nothing here is built, tested, or deployed by this repository. The Pages
workflow prunes this directory before publishing, so none of it is served on
the public site -- do not put anything here that relies on being reachable
over HTTP, and do not add real credentials to `Web.config` even though it is
excluded.
