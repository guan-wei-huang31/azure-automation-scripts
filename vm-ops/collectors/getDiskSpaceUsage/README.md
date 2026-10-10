# Azure VM Guest Disk Space Usage

Collects the **actual filesystem usage inside the guest OS** of Azure VMs (size / used / free
per volume), maps every volume to the **Azure managed disk** that backs it, and writes one row
per volume to **Azure Table Storage**.

Platform metrics such as "OS/Data Disk IOPS Consumed Percentage" only say how close a disk is
to its IOPS/throughput limit. They say nothing about how *full* it is. Used/free space is known
only to the guest OS, so it has to be collected by running a command inside the VM.

## Files

| File | Runs on | Purpose |
|---|---|---|
| `Invoke-ScriptOnVms.ps1` | Operator machine / Automation | Orchestrator: finds VMs, creates the table and SAS tokens, deploys the collector through the Custom Script Extension, logs deployment failures |
| `Get-DiskSpaceUsage.ps1` | **Windows** VM | Collector (PowerShell 5.1+) |
| `Get-DiskSpaceUsage.sh` | **Linux** VM | Collector (bash 3.2+), same table and columns |

Both collectors take the same named parameters and write the same table, so Windows and Linux
results can be queried together.

> **Orchestrator scope:** `Invoke-ScriptOnVms.ps1` currently deploys the **Windows** collector
> only (`Microsoft.Compute` / `CustomScriptExtension`, `powershell.exe`). The Linux collector
> works standalone; deploying it fleet-wide needs the Linux extension type
> (`Microsoft.Azure.Extensions` / `CustomScript`) and a bash command line, which is not yet
> implemented in the orchestrator.

## How it works

```text
Invoke-ScriptOnVms.ps1
  1. sign in (managed identity or current Az context)
  2. Resource Graph query -> running VMs matching -QueryScope
  3. ensure table + private container, generate table SAS (add/update) and script blob SAS
  4. upload collector script to blob
  5. Set-AzVMExtension per VM (parallel, -ThrottleLimit), SAS passed in protectedSettings
  6. on deployment failure: write one error row for that VM
        |
        v
Collector on the VM
  - usage:       per volume size / used / free
  - correlation: volume -> physical disk -> LUN / OS flag -> Azure managed disk (via IMDS)
  - report:      one MERGE per volume to Azure Table Storage over HTTPS + SAS
```

Azure disk correlation uses the **Instance Metadata Service** (`169.254.169.254`), which is
answered by the host and needs no Azure credentials.

## Quick start

### Orchestrator (Windows VMs)

```powershell
# defaults: storage account stdiskusagetest01, extension name GoCloudCustomScript, Windows VMs
.\Invoke-ScriptOnVms.ps1

# one test VM only (recommended for the first run)
.\Invoke-ScriptOnVms.ps1 -QueryScope "name =~ 'vm-diskusage-wi'"

# unattended, e.g. Azure Automation
.\Invoke-ScriptOnVms.ps1 -UseManagedIdentity -ThrottleLimit 20 -RemoveExtensionAfterRun
```

| Parameter | Default | Meaning |
|---|---|---|
| `-StorageAccountName` | `stdiskusagetest01` | Account holding the results table and the script container |
| `-StorageResourceGroupName` | *(looked up by name)* | Resource group of the account |
| `-StorageSubscriptionId` | *(current / where found)* | Subscription of the account |
| `-TableName` | `AzureVMDiskUsage` | Results table (created if missing) |
| `-ExtensionName` | `GoCloudCustomScript` | Name of the extension deployed on each VM |
| `-ContainerName` | `vm-ops-scripts` | Private container used to stage the script |
| `-ScriptPath` | `Get-DiskSpaceUsage.ps1` next to the orchestrator | Collector to deploy |
| `-QueryScope` | `vmOSType =~ 'Windows'` | KQL predicate appended as `\| where ...`; columns: `name`, `resourceGroup`, `subscriptionId`, `location`, `tags`, `vmOSType` |
| `-SubscriptionIds` | all visible | Limit the VM query |
| `-ThrottleLimit` | `10` | Concurrent deployments |
| `-SasValidityHours` | `6` | Lifetime of the generated SAS tokens |
| `-UseManagedIdentity` | off | `Connect-AzAccount -Identity` |
| `-RemoveExtensionAfterRun` | off | Remove the extension after each VM finishes |

Required modules: `Az.Accounts`, `Az.Compute`, `Az.Storage`, `Az.ResourceGraph`.
Required roles: Virtual Machine Contributor on the target VMs, and listKeys on the storage
account (e.g. Storage Account Key Operator).

### Collector, run directly

```powershell
# Windows
.\Get-DiskSpaceUsage.ps1 -AccountName stdiskusagetest01 -SasToken $TableSas -RunId test-001 `
    -TableName AzureVMDiskUsage
```

```bash
# Linux (run as root; options accept --AccountName, -AccountName, --account-name, --account-name=...)
sudo ./Get-DiskSpaceUsage.sh --account-name stdiskusagetest01 --sas-token "$TABLE_SAS" \
    --run-id test-001 --table-name AzureVMDiskUsage
```

| Parameter | Meaning |
|---|---|
| `AccountName` | Storage account name |
| `SasToken` | Table-scoped SAS, query-string form (add/update permission) |
| `RunId` | Correlation id for the run |
| `TableName` | Table to write to; must match the SAS (default `AzureVMDiskUsage`) |
| `AzureVmId` | ARM resource id of the VM (used for `VMName` / `ResourceId`) |
| `SubscriptionName`, `SubscriptionId` | Reporting only |

Never commit SAS tokens to source control or logs.

## Important points

1. **One row per volume**, not per VM. `RowKey` = `<hostname>_<volume>`. All rows of a run share
   `RunId` / `HostName`, so they can be grouped back together.
2. **The table holds the latest state, not history.** `PartitionKey` is the table name, `RowKey`
   has no `RunId`, and every run MERGEs into the same keys. Two VMs with the same hostname
   (different subscriptions / resource groups) would overwrite each other. Decide whether you
   need history before using this for trending.
3. **MERGE is an upsert here** (no `If-Match` header: insert-or-merge), so rows are created on
   first write. It does **not remove fields**, and a `null` does not clear an old value, so a
   detached disk can leave a stale `AzureDiskName` until the row is replaced.
4. **`UsedGB` is defined differently by OS (by design).**

   | | Windows | Linux |
   |---|---|---|
   | `SizeGB` | volume size | `df` size |
   | `UsedGB` | `SizeGB - FreeGB` | `df` **Used**: blocks actually holding data (reserved-for-root blocks excluded; this is what a backup copies) |
   | `FreeGB` | `SizeRemaining` | `df` **Available** (what non-root users can use) |
   | `PercentFree` | `FreeGB / SizeGB` | `Available / Size`, from the raw KiB values (not the rounded GB) |

   On Linux `UsedGB + FreeGB` can be below `SizeGB` by the reserved blocks. GB means GiB
   (1,073,741,824 bytes) on both.
5. **Azure correlation is best-effort and never guessed.** If IMDS is unreachable or a disk
   cannot be matched, `LUN` / `AzureDisk*` stay `null` and `Error` is still `None`. Usage values
   are collected independently and are always reported. `AzureDiskSizeGB` is the provisioned
   managed-disk size; `SizeGB` is the guest volume size.
6. **Temporary / resource disks are not managed disks**, so they have no Azure disk columns.
7. **A volume can span several disks** (Linux LVM / RAID). Then `LUN`, `AzureDiskName` and
   `AzureDiskResourceId` are comma-separated and `AzureDiskSizeGB` is the sum.
8. **A VM can have only one Custom Script Extension handler.** The orchestrator deploys under the
   name `GoCloudCustomScript`; if a VM already has that extension, **its settings are replaced**
   by this run. Test on one VM first.
9. **SAS handling.** The table SAS is limited to the one table, add/update only, and short-lived.
   It travels in the extension's `protectedSettings` (encrypted). On Linux, curl receives the
   URL on stdin (`-K -`) so the SAS is not in curl's argument list.
10. **No temp files.** Both collectors keep everything in variables (the bash script avoids
    here-strings/here-docs too, since older bash implements those with temp files).
11. **Linux needs `curl`** (bash has no HTTPS client). Everything else is bash builtins plus
    `df`, `readlink`, `date`, `tr`; no `jq`, Python, or `lsblk`.

## Table schema

| Property | Windows | Linux |
|---|---|---|
| `PartitionKey` | table name | table name |
| `RowKey` | `<hostname>_<DriveLetter>` | `<hostname>_root`, `<hostname>_<mountpath with / as _>` |
| `RunId`, `StartTime`, `EndTime` | yes | yes |
| `HostName`, `VMName`, `ResourceId` | yes | yes |
| `SubscriptionName`, `SubscriptionId` | yes | yes |
| `DriveLetter` | `C:` | the mount point, e.g. `/`, `/data` |
| `FileSystemLabel`, `FileSystem` | yes | yes |
| `SizeGB`, `UsedGB`, `FreeGB`, `PercentFree` | yes | yes (see point 4) |
| `DiskNumber` | Windows disk number | always `null` |
| `LUN`, `IsOsDisk` | yes | yes |
| `AzureDiskName`, `AzureDiskResourceId`, `AzureDiskSizeGB` | yes | yes |
| `Device` | - | filesystem source, e.g. `/dev/sda1`, `/dev/mapper/rootvg-rootlv` |
| `DiskDevice` | - | underlying kernel disk(s), e.g. `sda`, `sdc,sdd` |
| `Error` | `None` or message | `None` or message |

Linux `RowKey`: if two mount points sanitise to the same key (e.g. `/var/lib` and `/var_lib`),
both get a stable 8-character hash suffix so neither overwrites the other.

## Error handling

| Condition | Result |
|---|---|
| IMDS unreachable / disk not matched | Usage is still reported; Azure columns `null`; `Error` = `None` |
| Collector cannot start (bad/missing account, SAS, no curl) | Nothing can be written; message on stderr, exit 1 (visible in the extension status) |
| No fixed volumes found | One row, RowKey = hostname, `Error` = `No fixed volumes found` |
| Collection fails | One row, RowKey = hostname, `Error` = `Disk space collection failed: <reason>`, exit 1 |
| *(Linux)* one volume's usage cannot be read | That volume gets its own row with the error; other volumes continue; exit 1 at the end |
| *(Linux)* one row's table write fails | Remaining volumes are still written; best-effort host summary row; exit 1 |
| *(Linux)* terminated (SIGTERM / unexpected exit) | Safety net writes a "terminated unexpectedly" row |
| Extension fails to deploy | The orchestrator writes a row for that VM, `Error` = `Orchestrator: ...` |

A failure row and the volume rows of the same host use different RowKeys, except the
orchestrator's row, which uses the VM name (usually equal to the hostname) and therefore MERGEs
into the collector's host-level row.

## Limitations

- Windows: only fixed volumes **with a drive letter** are reported; mounted folders without a
  letter are skipped. Storage Spaces and unusual layouts may not map to a single disk.
- Linux: data-disk LUNs come from Azure's udev links (`/dev/disk/azure/scsi1/lunN`,
  `/dev/disk/azure/data/by-lun/N`), with a sysfs fallback. NVMe disks are only mapped when those
  links exist.
- Linux: one row per backing device. Bind mounts and Btrfs subvolumes of the same device collapse
  into one row (the one mounted at `/` is preferred).
- Linux: loop devices, optical drives, RAM disks and non-`/dev` sources (tmpfs, overlay, NFS)
  are excluded.
- Windows (`Get-DiskSpaceUsage.ps1`, last catch block): the warning message uses
  `$_Exception.Message`, which is a typo for `$_.Exception.Message`.

## Test status

- **Windows collector:** run on a Windows VM; OS disk and data disk rows reported with Azure disk
  mapping.
- **Linux collector:** run on an Ubuntu VM (OS disk `/`, `/boot/efi`, data disk `/data`).
  Subsequent changes (LUN mapping via Azure udev links, `df` Used for `UsedGB`, PercentFree from
  raw KiB, error handling) were made after that run and **have not been re-run on a VM yet**.
  RHEL/Rocky/Alma (including LVM), SLES, NVMe and md RAID are untested.
- **Orchestrator:** written but not yet run against real VMs.

## Pre-deployment checklist

- [ ] Run the orchestrator against **one** Windows VM (`-QueryScope "name =~ '<vm>'"`) and check the rows.
- [ ] Confirm the account allows shared-key access (the orchestrator uses `listKeys`); otherwise switch it to Entra ID authorization.
- [ ] Confirm replacing `GoCloudCustomScript` on target VMs is acceptable.
- [ ] Decide latest-state vs history before relying on the table for trends (points 2 and 3).
- [ ] Re-run the Linux collector on Ubuntu, then on a RHEL-family VM with LVM, and on SLES.
- [ ] Add Linux support to the orchestrator if Linux VMs should be collected fleet-wide.
- [ ] Test failure paths: invalid SAS, IMDS blocked, a VM that already has a different extension.
