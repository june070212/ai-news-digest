# 01.02 — Introduce Central Package Management

Add `Directory.Packages.props` at the solution root and move every `PackageReference`
version out of the individual project files, so the Newtonsoft.Json drift (13.0.3 / 12.0.3 /
11.0.2) is resolved once rather than three times.

**Exit criteria**: `ManagePackageVersionsCentrally` is enabled, no project file carries a
`Version` attribute, and the build still produces 0 errors.
