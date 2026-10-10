# Azure Automation Scripts

A collection of scripts for operating and reporting on Azure resources. Scripts are grouped by
**purpose** (the top-level folder), then by **role** and **task**, so the repository can grow
without each new script needing its own conventions.

## Repository layout

```text
azure-automation-scripts/
|-- README.md                  <- you are here
`-- <purpose>/                 e.g. vm-ops
    `-- <role>/                e.g. collectors
        `-- <task>/            e.g. getDiskSpaceUsage
            |-- README.md      task documentation (start here)
            `-- *.ps1 / *.sh   scripts
```

| Level | Meaning |
|---|---|
| **purpose** | The area a script serves (virtual machine operations, and later e.g. storage, networking, cost, security). |
| **role** | What the script does in that area (e.g. `collectors` gather data; other roles can be added as needed). |
| **task** | One self-contained job, with its own README, scripts and parameters. |

## Catalog

| Purpose | Task | What it does | Platforms | Docs |
|---|---|---|---|---|
| `vm-ops` | `collectors/getDiskSpaceUsage` | Collects actual guest-OS disk usage per volume, maps each volume to its Azure managed disk, and reports to Azure Table Storage | Windows (PowerShell), Linux (bash) | [README](vm-ops/collectors/getDiskSpaceUsage/README.md) |

Add a row here whenever a task is added.

## Common pattern

Tasks that run *inside* VMs follow the same two-part shape:

```text
Orchestrator (operator machine / Azure Automation)
  - signs in to Azure, selects target VMs, creates short-lived credentials
  - dispatches the collector to each VM (e.g. Custom Script Extension)
        |
        v
Collector (runs on the VM)
  - does the local work, reports results to a central store
```

This keeps the on-VM script small, dependency-free and independent of the orchestration method.

## Conventions

These are the conventions used so far; follow them for new scripts unless there is a reason not to.

- **Named parameters with defaults.** Scripts that run non-interactively (such as under the
  Custom Script Extension) must never wait for input. A missing value should fail fast with a
  clear message, not hang.
- **No secrets in the repository.** SAS tokens, keys and connection strings are generated at run
  time and passed by the orchestrator. Do not commit them or print them to logs.
- **Least-privilege, short-lived credentials.** For example, a SAS scoped to a single table,
  add/update only, valid for hours.
- **Report failures as data.** Where there is a results store, a failure should leave a row that
  explains it, not only an exit code.
- **Best-effort enrichment is never guessed.** If an optional lookup cannot be proven, leave the
  field empty rather than filling in a plausible value.
- **Few dependencies on the target VM.** PowerShell 5.1 on Windows; bash plus standard system
  tools on Linux (no Python, `jq` or extra modules required).
- **Equivalent behavior across OSes.** When a task has both a Windows and a Linux script, they
  take the same parameters and write the same schema.
- **Document each task** in its own README: purpose, parameters, output schema, error handling,
  known limitations and test status.

## Prerequisites

| Where | Needs |
|---|---|
| Operator machine / Automation | PowerShell 5.1+ or 7, Azure `Az` modules as listed in the task README (commonly `Az.Accounts`, `Az.Compute`, `Az.Storage`, `Az.ResourceGraph`) |
| Azure | Roles on the target resources as listed in the task README |
| Target VM | OS-specific; see the task README |

## Adding a new task

1. Create `<purpose>/<role>/<task>/` (reuse an existing purpose and role where one fits).
2. Add the scripts and a task `README.md` covering the items listed under *Conventions*.
3. Add a row to the **Catalog** table above.
4. State test status honestly in the task README: what was run, where, and what was not.

## Safety

Scripts that deploy extensions, write to storage, or change resources act on live Azure
environments. Run against a single test resource first, and read the task README's
"Important points" before running across a fleet.
