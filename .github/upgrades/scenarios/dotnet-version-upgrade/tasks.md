# Migration Progress

**Progress**: 7/16 tasks complete <progress value="44" max="100"></progress> 44%
**Status**: In Progress - Task 03.02-contoso-orders-jobs
**Started**: 2026-08-07
**Last Updated**: 2026-08-09 09:41

## Overview

Upgrading the ContosoOrders solution from .NET Framework 4.7.2 to .NET 8.0 using a
bottom-up strategy. Preparation and SDK-style conversion are complete; retargeting is
underway. One task (`05.02-remoting-removal`) failed on its first attempt and is awaiting
a re-architecture decision.

## Task Hierarchy

- ✅ 01-preparation: Preparation
  - ✅ 01.01-baseline-build: Establish green baseline build
  - ✅ 01.02-central-package-management: Introduce Directory.Packages.props
- ✅ 02-sdk-style-conversion: Convert legacy projects to SDK-style
  - ✅ 02.01-contoso-orders-web: Convert Contoso.Orders.Web to SDK-style
  - ✅ 02.02-contoso-orders-jobs: Convert Contoso.Orders.Jobs to SDK-style
- 🔄 03-retarget-frameworks: Retarget projects to net8.0
  - ✅ 03.01-contoso-orders-web: Retarget Contoso.Orders.Web to net8.0
  - 🔄 03.02-contoso-orders-jobs: Retarget Contoso.Orders.Jobs to net8.0
- 🔲 04-dependency-remediation: Remediate NuGet dependencies
  - 🔲 04.01-system-data-sqlclient: Replace System.Data.SqlClient with Microsoft.Data.SqlClient
  - 🔲 04.02-newtonsoft-consolidation: Consolidate Newtonsoft.Json to 13.0.3
- 🔲 05-api-remediation: Remediate removed and changed APIs
  - 🔲 05.01-configurationmanager: Migrate ConfigurationManager to IConfiguration
  - ❌ 05.02-remoting-removal: Replace System.Runtime.Remoting job dispatcher
- 🔲 06-validation: Full solution build and test validation

**Legend**: ✅ Complete | 🔄 In Progress | 🔲 Pending | ⚠️ Blocked | ❌ Failed

## Current Focus
🔄 **03.02-contoso-orders-jobs**: Retarget Contoso.Orders.Jobs to net8.0
[Details](tasks/03.02-contoso-orders-jobs/task.md) | [Changes](tasks/03.02-contoso-orders-jobs/progress-details.md)

## Recent Activity
- 2026-08-09 09:41: Started 03.02-contoso-orders-jobs
- 2026-08-09 09:28: Failed 05.02-remoting-removal - no .NET 8 replacement for System.Runtime.Remoting; needs re-architecture decision
- 2026-08-09 08:55: Completed 03.01-contoso-orders-web - retargeted to net8.0, 9 System.Web errors deferred to 05-api-remediation
- 2026-08-08 16:12: Completed 02.02-contoso-orders-jobs - converted to SDK-style, still on net472
- 2026-08-08 14:03: Completed 02.01-contoso-orders-web - converted to SDK-style, 41 files removed from explicit compile list
- 2026-08-07 15:20: Completed 01.02-central-package-management - Newtonsoft.Json drift resolved (3 versions to 1)
- 2026-08-07 10:02: Completed 01.01-baseline-build - baseline green, 0 errors / 12 warnings
- 2026-08-07 09:24: Plan generated - 16 tasks across 6 phases

## Statistics
- Total Tasks: 16
- Completed: 7 (44%)
- Files Modified: 23
- Projects Updated: 3/5
