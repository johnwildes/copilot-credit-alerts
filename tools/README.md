# Set-CopilotCreditCaps.ps1

Sets a Copilot Studio credit cap on Power Platform environments. The Power
Platform admin center does this **one environment at a time**; this script does
it across all of them at once.

For each environment it:

1. **Allocates** a given number of Copilot credits.
2. **Closes the tenant-pool draw** (`TenantPool = false`), so the environment
   stops at its own allocation instead of drawing from the tenant's unallocated
   pool with no ceiling.

That second step is the point: an environment with no cap draws from shared
tenant capacity and can spend the whole tenant. Capping every environment
contains the blast radius no matter who builds what.

It calls the documented `PUT https://api.powerplatform.com/licensing/allocationsV2`
(api-version `2024-10-01`, entitlement `MCSMessages`).

> **Dry-run is the default.** Without `-Apply` the script only makes read calls
> and changes nothing.

## Requirements

| | |
|---|---|
| Role | **Power Platform Administrator** or **Global Administrator** |
| PowerShell | Windows PowerShell 5.1 or PowerShell 7 |
| Sign-in | Az PowerShell module **or** Azure CLI (either one) |

The Az PowerShell module installs into the user profile without admin rights and
needs no app registration:

```powershell
Install-Module Az.Accounts -Scope CurrentUser
```

## Run

```powershell
# 1. Sign in
Connect-AzAccount -TenantId <tenant-id>          # Az module
#   or:  az login --tenant <tenant-id>           # Azure CLI

# 2. Dry-run — changes nothing, lists every environment and what can be allocated
.\Set-CopilotCreditCaps.ps1 -UseAzModule -AllEnvironments

# 3. Apply — sets a 1000-credit cap on every environment and closes the pool draw
.\Set-CopilotCreditCaps.ps1 -UseAzModule -AllEnvironments -Quantity 1000 -Apply
```

Use `-UseAzCli` instead of `-UseAzModule` if you signed in with Azure CLI.
Each environment is reported on its own line (OK / FAIL); a single failure does
not stop the run. There is a 400 ms pause between calls as throttle protection.

> ⚠️ If many environments FAIL, the likeliest cause is that the tenant ran out of
> allocatable capacity: an allocation reserves credits from the tenant pool, so
> the total across environments cannot exceed purchased capacity. That is a
> signal to reconsider the cap or the number of environments, not a script bug.

## Parameters

| Parameter | Meaning |
|---|---|
| `-AllEnvironments` | Fetch every environment in the tenant automatically |
| `-EnvironmentId <id>` | A single environment |
| `-EnvironmentCsv <path>` | List from a file, column `environmentId` |
| `-Quantity <n>` | Credits to allocate. Default 0. |
| `-AllowTenantPool $true` | Allow drawing from the tenant pool. Default `$false`. |
| `-Apply` | **Writes.** Without it, dry-run only. |
| `-UseAzModule` / `-UseAzCli` | Which sign-in to use |
| `-DelayMs <ms>` | Pause between calls, default 400 |

## Verify in the admin center

**admin.powerplatform.microsoft.com → Licensing → Products → Copilot Studio**

- Per environment (*Manage Copilot Credits*): an allocation is set, and
  *Capacity overages → Draw from the available capacity in my tenant* is **off**.
- Overall (*Summary → Prepaid capacity*): compare allocated against purchased to
  confirm the cap fit the whole environment list.

## Reverting

Re-run with a different `-Quantity`, or change it by hand in the admin center
under **Licensing → Products → Copilot Studio → Manage Copilot Credits**.
