# Copilot Credit Alerts

A Power Platform solution that tells **the owner of a Copilot Studio agent** when the
environment their agent runs in is running out of Copilot credits.

The Power Platform admin center already alerts on credit limits, but those notifications
go to tenant and environment administrators. The person who can actually do something
about a specific agent, its owner, is never told. This closes that gap.

> ⚠️ **This reads billing and governance data across your whole tenant.** It is provided
> as-is with no warranty. Read it before pointing it at a tenant you care about.

## Read this before you install it

**Consumption cannot be attributed to individual agents.** The Power Platform inventory
exposes an agent's name, owner, environment, model, channels and connectors, but not its
credit consumption. `Resource Threshold` is documented as a write operation only.

That has a consequence you have to accept: the trigger is **environment-level**, and every
harness-agent owner in that environment is notified. If ten agents share an environment and
one of them burns the credits, the other nine owners are told too. The email says so
explicitly rather than implying the recipient caused it.

If you need per-agent attribution, this solution cannot give it to you and neither can the
API today.

## What it does

Once a day:

1. List every environment in the tenant
2. Query the inventory once for every Copilot Studio agent, with owner and harness flag
3. For each environment, read its Copilot credit position
4. If the environment is at risk, email the owner of each GitHub Copilot harness agent in it
5. Write a row to an alert log table

## When it alerts

```
environment consumed >= 80% of its allocation
   OR
allocation is 0 and there is consumption
```

The second condition matters more than it looks. An environment with no allocation of its own
cannot cross a percentage threshold, but it is still consuming, and that consumption comes
out of capacity shared with every other environment. A percentage rule alone would never
have fired on it.

Owners are not reminded about the same agent more than once every seven days.

## The alert log

One row per alert, not one row per day. The table answers the question the built-in
notification leaves open: **who owns this, and have they been told.**

| Column | Holds |
|---|---|
| Agent, Agent ID | which agent |
| Owner email | who owns it |
| Owner notified | whether the mail went out |
| Environment, Environment ID | where |
| Alert sent | when |
| Allocated, Consumed, Percent used | the numbers at the time |
| Tenant pool enabled | whether the environment can draw from shared capacity |
| Harness agents in environment | how many owners were notified for the same event |

An administrator who receives the built-in Microsoft alert can look here and find the owner.

## Prerequisites

- **Power Platform Administrator** or Global Administrator
- **Power Automate Premium** for the flow's owner. One licence, not per recipient
- Dataverse in the environment where the solution is installed
- [Power Platform CLI](https://aka.ms/PowerPlatformCLI)

You do **not** need an app registration. The *HTTP with Microsoft Entra ID* connector
authenticates as the connection owner, so an administrator can create the connection as
themselves.

Do create one when the solution is staying somewhere permanently: a connection tied to a
personal account breaks when that person leaves, and until then every nightly run carries
their name in the audit log.

## Install

```bash
pac auth create --environment <env-id>
pac solution pack --zipfile ccg.zip --folder src --packagetype Unmanaged
pac solution import --path ccg.zip --environment <env-id> \
    --force-overwrite --publish-changes
```

The solution ships five connection references. Bind them at import:

| Connector | Used for |
|---|---|
| HTTP with Microsoft Entra ID | credits and inventory, resource `https://api.powerplatform.com` |
| Power Platform for Admins | listing environments |
| Microsoft Dataverse | writing the alert log |
| Office 365 Users | resolving owner ID to an email address |
| Office 365 Outlook | sending the alert |

Then turn the flow on. It runs at 03:00 in FLE Standard Time; change the recurrence if that
does not suit you.

**Test it without spending credits.** Temporarily relax the condition so it fires whenever an
environment contains a harness agent, and point the recipient at your own address. Run once,
confirm the mail, then restore both. That is how this was verified.

## Notes for anyone extending this

Things that cost a run each while building it:

1. **`toLower` on both sides when matching environment IDs.** The inventory returns the
   default environment as `default-<tenantId>`; the admin API returns `Default-<tenantId>`.
   Without case folding you get zero agents, silently, with no error.
2. **Credits are decimals.** `int(20872.5)` fails with *"The template language function 'int'
   was invoked with a parameter that is not valid."* Dataverse columns must be `decimal`, and
   a column's type cannot be changed after it is created.
3. **Format the numbers.** A raw float prints as `32.50000000000001`. Use
   `formatNumber(x, '0.##')`.
4. **`ownerId` can be all zeros** for system-owned agents. There is nobody to email.
5. **Create connections before importing a flow that references them.** A connection
   reference that cannot be bound locks the flow editor completely, and you cannot get in to
   fix it.
6. **Own your connection references.** If they are created implicitly while editing, they can
   end up with another solution's publisher prefix, and the package then carries an unmanaged
   dependency that fails on import elsewhere. Solution Checker catches this; the email it
   sends is worth reading.
7. **`pac solution pack` succeeds on packages that cannot be imported.** Only the import tells
   the truth.

### Endpoints

```
GET  /licensing/environments/<envId>/entitlements?api-version=2024-10-01
     filter for entitlementId == 'MCSMessages'
     capacity.allocated.value, consumed.value, availableQuantity, enforcementRules[]

POST /resourcequery/resources/query?api-version=2024-10-01
     type == 'microsoft.copilotstudio/agents'
     project name, displayName, environmentId, ownerId, isCLIAgent
```

`allocationsByEnvironment/<envId>` does not exist. `allocationsV2` without `/availability` is
a PUT; a GET returns `AllocationDocumentDoesNotExist` when the environment has no allocation,
which is itself a useful signal rather than an error.

The inventory rate limit is tight: around 15 requests before a five second reset. Loops run
one at a time.

## A note on the solution name

The Dataverse solution is still called `CopilotCreditGovernance` internally. Renaming a
solution's unique name makes the next import create a second solution instead of upgrading
the first, so it was left alone.

## Background

The governance process this implements is described by the Microsoft CAT team in
[Adopting the GitHub Copilot Harness: Cost Control and Governance in Copilot Studio](https://microsoft.github.io/mcscatblog/posts/copilot-harness-cost-governance/).
That article documents the process; this is one implementation of the part it leaves to you.

## Licence

MIT. See [LICENSE](LICENSE).
