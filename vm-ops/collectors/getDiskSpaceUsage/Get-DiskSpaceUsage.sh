#!/bin/bash
#
# .SYNOPSIS
#     Collects ACTUAL guest-OS disk space usage (size/used/free per local volume) on a Linux VM
#     and reports one result row per volume to Azure Table Storage.
#
# .DESCRIPTION
#     Linux counterpart of Get-DiskSpaceUsage.ps1. Designed to run ON a target Linux VM via the
#     Custom Script Extension dispatched by the orchestrator, receiving all inputs as named
#     parameters. Writes the same table, with the same columns, as the Windows script so both
#     can be queried together.
#
#     One row per local volume, RowKey = "<hostname>_<mountpoint>" ("/" becomes "root", other
#     mount points have the leading "/" removed and remaining "/" replaced by "_"), all sharing
#     the same RunId/HostName. Column mapping vs. the Windows script:
#
#         DriveLetter  -> the mount point (e.g. "/", "/data")
#         DiskNumber   -> not applicable on Linux (left null)
#         LUN          -> Azure LUN of the backing data disk (from the sysfs SCSI address)
#         Device       -> (extra) filesystem source, e.g. /dev/sda1 or /dev/mapper/rootvg-rootlv
#         DiskDevice   -> (extra) underlying kernel disk(s), e.g. sda or sdc,sdd (LVM/md aware)
#
#     Azure disk correlation: each mount is resolved to its underlying whole disk(s) through
#     /sys (partitions, LVM / device-mapper and md RAID are followed down to the real disks), the
#     LUN is read from the disk's SCSI address on the Azure data-disk controller, and joined to
#     the Azure Instance Metadata Service (IMDS, 169.254.169.254) disk list by LUN (data disks)
#     or by the OS-disk flag (disks backing "/"). If a volume spans several disks (LVM stripe,
#     md RAID) LUN/AzureDiskName/AzureDiskResourceId are comma-separated and AzureDiskSizeGB is
#     the sum. If IMDS is unreachable or a lookup fails those columns are left null - the core
#     SizeGB/UsedGB/FreeGB values are always collected independently.
#
#     Space values: SizeGB = filesystem size, UsedGB = blocks actually holding data (df "Used";
#     reserved-for-root blocks are NOT counted, so this is what a backup would copy), FreeGB =
#     space available to non-root users (df "Available"), PercentFree = FreeGB / SizeGB, as in
#     the Windows script. On Linux UsedGB + FreeGB can be less than SizeGB by the reserved blocks.
#
#     Uses only bash builtins plus tools present on every mainstream distribution (RHEL/CentOS/
#     Rocky/Alma, Ubuntu/Debian, SLES, Oracle Linux): df, readlink, date, tr and curl (required;
#     bash has no HTTPS client of its own). No jq/python/lsblk and NO temp files - everything is
#     held in shell variables.
#
#     RowKey: two mount points that sanitise to the same key (e.g. /var/lib and /var_lib) are
#     both given a stable hash suffix, so one never overwrites the other.
#
# .PARAMETER AccountName       Azure Storage account name hosting the results table.
# .PARAMETER SasToken          SAS token (query-string form) scoped to -TableName.
# .PARAMETER RunId             Correlation ID supplied by the orchestrator for this run.
# .PARAMETER TableName         Results table (default AzureVMDiskUsage). Must match the SAS.
# .PARAMETER AzureVmId         Full ARM resource ID of this VM (used for VMName / ResourceId).
# .PARAMETER SubscriptionName  Subscription display name, for reporting only.
# .PARAMETER SubscriptionId    Subscription ID, for reporting only.
#
#     Options are accepted as --AccountName value, -AccountName value or --AccountName=value
#     (case-insensitive; --account-name also works). Unknown options are ignored.
#
# .EXAMPLE
#     bash Get-DiskSpaceUsage.sh --AccountName stdiskusagetest01 --SasToken 'sv=...&sig=...' \
#         --RunId 5f1c... --TableName AzureVMDiskUsage --AzureVmId /subscriptions/.../vm01 \
#         --SubscriptionName MySub --SubscriptionId 0000...
#
# .NOTES
#     Needs bash 3.2+ and root (the Custom Script Extension runs as root). Outbound HTTPS to
#     <account>.table.core.windows.net and, for disk correlation, link-local access to IMDS.
#     LUN correlation covers SCSI-attached disks (the default for Azure VM families that use
#     SCSI); NVMe-attached disks are reported but their Azure columns stay null.

# Re-exec under bash if launched by `sh script.sh` (dash etc.); everything below needs bash.
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

export LC_ALL=C

#region Parameters -------------------------------------------------------------------------

# All parameters have defaults ON PURPOSE: the Custom Script Extension is non-interactive and
# a missing value must fail fast, not wait for input.
AccountName=""
SasToken=""
RunId=""
TableName="AzureVMDiskUsage"
AzureVmId=""
SubscriptionName=""
SubscriptionId=""

while [ $# -gt 0 ]; do
    opt=$1
    case $opt in
        -*)
            key=${opt#"${opt%%[!-]*}"}          # strip leading dashes
            if [[ $key == *=* ]]; then
                val=${key#*=}
                key=${key%%=*}
                shift
            else
                val=${2-}
                if [ $# -ge 2 ]; then shift 2; else shift; fi
            fi
            key=$(printf '%s' "$key" | tr 'A-Z' 'a-z' | tr -d '_-')
            case $key in
                accountname)      AccountName=$val ;;
                sastoken)         SasToken=$val ;;
                runid)            RunId=$val ;;
                tablename)        TableName=$val ;;
                azurevmid)        AzureVmId=$val ;;
                subscriptionname) SubscriptionName=$val ;;
                subscriptionid)   SubscriptionId=$val ;;
            esac
            ;;
        *) shift ;;
    esac
done

# Guard against stray leading/trailing whitespace (copy-paste, interactive prompts).
trim() {
    local v=$1
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    printf '%s' "$v"
}
AccountName=$(trim "$AccountName")
SasToken=$(trim "$SasToken")
SasToken=${SasToken#\?}                          # tolerate a leading '?'
RunId=$(trim "$RunId")
TableName=$(trim "$TableName")
[ -n "$TableName" ] || TableName="AzureVMDiskUsage"

#endregion Parameters

#region Generic helpers --------------------------------------------------------------------

ERR_MSG=""

json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    s=${s//[[:cntrl:]]/ }
    printf '%s' "$s"
}

# Percent-encode into $REPLY (no subshell).
urlencode() {
    local s=$1 out="" c h i
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        case $c in
            [A-Za-z0-9._~-]) out+=$c ;;
            *) printf -v h '%%%02X' "'$c"; out+=$h ;;
        esac
    done
    REPLY=$out
}

# Hundredths (integer) -> "12", "12.5", "12.34" - same look as PowerShell's rounded double.
fmt_hundredths() {
    local h=$1 i f
    [ "$h" -lt 0 ] && h=0
    i=$((h / 100))
    f=$((h % 100))
    if [ "$f" -eq 0 ]; then
        printf '%s' "$i"
    elif [ $((f % 10)) -eq 0 ]; then
        printf '%s.%s' "$i" "$((f / 10))"
    else
        printf '%s.%02d' "$i" "$f"
    fi
}

fmt_tenths() {
    local t=$1
    if [ $((t % 10)) -eq 0 ]; then
        printf '%s' "$((t / 10))"
    else
        printf '%s.%s' "$((t / 10))" "$((t % 10))"
    fi
}

# Entity (JSON) builder: accumulates into $ENT.
ENT=""
ent_raw() { ENT+="${ENT:+,}\"$1\":$2"; }
ent_str() {
    if [ -n "$2" ]; then ent_raw "$1" "\"$(json_escape "$2")\""; else ent_raw "$1" null; fi
}
ent_num() {
    if [[ $2 =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then ent_raw "$1" "$2"; else ent_raw "$1" null; fi
}
ent_bool() {
    case $2 in
        true | false) ent_raw "$1" "$2" ;;
        *) ent_raw "$1" null ;;
    esac
}
ent_common() {
    ent_str RunId "$RunId"
    ent_str StartTime "$StartTime"
    ent_str HostName "$HostName"
    ent_str VMName "$VMName"
    ent_str ResourceId "$AzureVmId"
    ent_str SubscriptionName "$SubscriptionName"
    ent_str SubscriptionId "$SubscriptionId"
}

# HTTP helper: curl is required (bash has no HTTPS client of its own).
HTTP_TOOL=""
if command -v curl >/dev/null 2>&1; then
    HTTP_TOOL=curl
fi

# Stable 8-hex-digit hash (djb2) of a string, pure bash. Used only to disambiguate row keys.
hash8() {
    local s=$1 h=5381 i c
    for ((i = 0; i < ${#s}; i++)); do
        printf -v c '%d' "'${s:i:1}"
        h=$(((h * 33 + c) & 0xFFFFFFFF))
    done
    printf '%08x' "$h"
}

# MERGE one entity. $1 PartitionKey, $2 RowKey, $3 JSON body. Returns 1 and sets ERR_MSG on failure.
write_entity() {
    local pk=$1 rk=$2 body=$3 uri resp rc code http_date pk_q rk_q cfg_url

    if [ "$HTTP_TOOL" != curl ]; then
        ERR_MSG="curl is required to reach Azure Table Storage but was not found"
        return 1
    fi

    pk_q=${pk//\'/\'\'}
    rk_q=${rk//\'/\'\'}
    urlencode "$pk_q"; pk_q=$REPLY
    urlencode "$rk_q"; rk_q=$REPLY
    uri="${TableUri}(PartitionKey='${pk_q}',RowKey='${rk_q}')?${SasToken}"
    http_date=$(date -u '+%a, %d %b %Y %H:%M:%S GMT')

    # The URL (which carries the SAS) is handed to curl as a config on stdin ("-K -") so it
    # never appears in curl's argument list / the process listing. printf is a builtin and a
    # pipe is not a file, so nothing touches disk.
    cfg_url=${uri//\\/\\\\}
    cfg_url=${cfg_url//\"/\\\"}
    resp=$(printf 'url = "%s"\n' "$cfg_url" | curl -sS -K - --max-time 60 -X MERGE \
        -H 'x-ms-version: 2017-07-29' \
        -H 'DataServiceVersion: 3.0;Netfx' \
        -H 'Accept-Charset: UTF-8' \
        -H 'Accept: application/json;odata=nometadata' \
        -H "Date: $http_date" \
        -H 'Content-Type: application/json;odata=nometadata' \
        --data-binary "$body" \
        -w $'\n%{http_code}' 2>&1)
    rc=$?
    code=${resp##*$'\n'}
    if [ $rc -ne 0 ]; then
        ERR_MSG="curl exit $rc: ${resp%$'\n'*}"
        return 1
    fi
    case $code in
        2??) return 0 ;;
        *)
            ERR_MSG="Table write returned HTTP $code: ${resp%$'\n'*}"
            return 1
            ;;
    esac
}

#endregion Generic helpers

#region IMDS -------------------------------------------------------------------------------

IMDS_OS_NAME=""
IMDS_OS_ID=""
IMDS_OS_SIZE=""
IMDS_LUN=()
IMDS_NAME=()
IMDS_ID=()
IMDS_SIZE=()
IMDS_OK=0

# First string value of "key":"value" in $1.
json_first() {
    local re="\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
    if [[ $1 =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

# Managed-disk resource id (skips e.g. diskEncryptionSet ids that precede it).
json_disk_id() {
    local re='"id"[[:space:]]*:[[:space:]]*"(/subscriptions/[^"]*/providers/[Mm]icrosoft\.[Cc]ompute/[Dd]isks/[^"]*)"'
    if [[ $1 =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

# Text of the { ... } object that follows "key": in $1 (brace matched).
json_object() {
    local s=$1 key=$2 rest i c depth=0
    [[ $s == *\"$key\"* ]] || return 1
    rest=${s#*\"$key\"}
    rest=${rest#*:}
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ "${rest:0:1}" = "{" ] || return 1
    for ((i = 0; i < ${#rest}; i++)); do
        c=${rest:i:1}
        case $c in
            '{') depth=$((depth + 1)) ;;
            '}')
                depth=$((depth - 1))
                if [ $depth -eq 0 ]; then
                    printf '%s' "${rest:0:i+1}"
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

# Authoritative Azure view of this VM's disks from IMDS (no credentials needed: answered by the
# host). Leaves IMDS_OK=0 and everything blank if IMDS is unreachable.
get_azure_disk_inventory() {
    local url='http://169.254.169.254/metadata/instance/compute/storageProfile?api-version=2021-12-13'
    local json os arr el IFS_SAVE lun

    [ "$HTTP_TOOL" = curl ] || return 1
    # --noproxy: IMDS is link-local and must never be sent through a proxy.
    json=$(curl -sf --noproxy '*' --max-time 5 -H 'Metadata: true' "$url" 2>/dev/null) || return 1
    [ -n "$json" ] || return 1

    json=${json//$'\n'/}
    json=${json//$'\r'/}

    if os=$(json_object "$json" osDisk); then
        IMDS_OS_NAME=$(json_first "$os" name)
        IMDS_OS_ID=$(json_disk_id "$os")
        IMDS_OS_SIZE=$(json_first "$os" diskSizeGB)
    fi

    if [[ $json == *'"dataDisks"'* ]]; then
        arr=${json#*\"dataDisks\"}
        arr=${arr#*\[}
        arr=${arr%%]*}
        arr=${arr//\},\{/$'\n'}
        IFS_SAVE=$IFS
        IFS=$'\n'
        set -f
        for el in $arr; do
            lun=$(json_first "$el" lun)
            [[ $lun =~ ^[0-9]+$ ]] || continue
            IMDS_LUN+=("$lun")
            IMDS_NAME+=("$(json_first "$el" name)")
            IMDS_ID+=("$(json_disk_id "$el")")
            IMDS_SIZE+=("$(json_first "$el" diskSizeGB)")
        done
        set +f
        IFS=$IFS_SAVE
    fi

    IMDS_OK=1
    return 0
}

#endregion IMDS

#region Disk resolution --------------------------------------------------------------------

DISK_LIST=""     # space separated kernel whole-disk names (result of collect_disks)
R_NAME=""        # kernel block device name (result of resolve_block)

add_disk() {
    case " $DISK_LIST " in
        *" $1 "*) ;;
        *) DISK_LIST="${DISK_LIST:+$DISK_LIST }$1" ;;
    esac
}

# Kernel block name for a mount source ($1) / major:minor ($2). Sets R_NAME.
resolve_block() {
    local real n
    R_NAME=""
    if [ -e "$1" ]; then
        real=$(readlink -f -- "$1" 2>/dev/null)
        n=${real##*/}
        if [ -n "$n" ] && [ -d "/sys/class/block/$n" ]; then
            R_NAME=$n
            return 0
        fi
    fi
    if [ -e "/sys/dev/block/$2" ]; then
        real=$(readlink -f "/sys/dev/block/$2" 2>/dev/null)
        n=${real##*/}
        if [ -n "$n" ] && [ -d "/sys/class/block/$n" ]; then
            R_NAME=$n
            return 0
        fi
    fi
    return 1
}

# Follow a block device down to the real whole disk(s): LVM/dm and md via "slaves",
# partitions via their sysfs parent. Appends to DISK_LIST.
collect_disks() {
    local n=$1 depth=${2:-0} sysdir slave found=0 real parent
    [ "$depth" -gt 8 ] && return
    sysdir=/sys/class/block/$n
    [ -d "$sysdir" ] || return

    if [ -d "$sysdir/slaves" ]; then
        for slave in "$sysdir"/slaves/*; do
            [ -e "$slave" ] || continue
            found=1
            collect_disks "${slave##*/}" $((depth + 1))
        done
        [ $found -eq 1 ] && return
    fi

    if [ -e "$sysdir/partition" ]; then
        real=$(readlink -f "$sysdir" 2>/dev/null)
        parent=${real%/*}
        parent=${parent##*/}
        [ -n "$parent" ] && add_disk "$parent"
    else
        add_disk "$n"
    fi
}

# Azure's own udev rules publish data disks as /dev/disk/azure/scsi1/lunN (SCSI) and
# /dev/disk/azure/data/by-lun/N (SCSI + NVMe). Load them once as device -> LUN.
AZ_LUN_DEV=()
AZ_LUN_NUM=()
ROOT_HOST=""

load_azure_lun_links() {
    local l name target
    for l in /dev/disk/azure/scsi1/lun* /dev/disk/azure/data/by-lun/*; do
        [ -L "$l" ] || continue
        name=${l##*/}
        name=${name#lun}
        [[ $name =~ ^[0-9]+$ ]] || continue          # skips lunN-partM
        target=$(readlink -f "$l" 2>/dev/null)
        [ -n "$target" ] || continue
        AZ_LUN_DEV+=("$target")
        AZ_LUN_NUM+=("$name")
    done
}

# Azure LUN of a whole disk ($1), empty if it is not an Azure data disk. The OS and
# temporary/resource disks are deliberately not given a LUN, so they cannot be mistaken
# for data LUN 0.
disk_lun() {
    local d=$1 real k lun host
    local re_hctl='/[0-9]+:[0-9]+:[0-9]+:([0-9]+)/block/'
    local re_host='/host([0-9]+)/'

    # 1. Authoritative: Azure udev links.
    for ((k = 0; k < ${#AZ_LUN_DEV[@]}; k++)); do
        if [ "${AZ_LUN_DEV[k]}" = "/dev/$d" ]; then
            printf '%s' "${AZ_LUN_NUM[k]}"
            return 0
        fi
    done
    # Links exist but this disk is not among them -> not a data disk.
    [ ${#AZ_LUN_DEV[@]} -gt 0 ] && return 0

    # 2. No udev links (rules not installed): infer from the SCSI address. Controller 0
    #    (VMBus ...-0000-8899-...) carries the OS/temp disk; data disks sit on another host.
    real=$(readlink -f "/sys/class/block/$d" 2>/dev/null)
    case $real in
        *-0000-8899-0000-000000000000/*) return 0 ;;
    esac
    [[ $real =~ $re_hctl ]] || return 0
    lun=${BASH_REMATCH[1]}
    [[ $real =~ $re_host ]] || return 0
    host=${BASH_REMATCH[1]}
    case $real in
        *-0001-8899-0000-000000000000/*) printf '%s' "$lun" ;;
        *)
            if [ -n "$ROOT_HOST" ] && [ "$host" != "$ROOT_HOST" ]; then printf '%s' "$lun"; fi
            ;;
    esac
}

#endregion Disk resolution

#region Snapshot ---------------------------------------------------------------------------

# Parallel arrays, one entry per volume.
V_MNT=(); V_ROOTFLAG=(); V_SRC=(); V_MM=(); V_FS=()
V_LABEL=(); V_SIZE=(); V_USED=(); V_FREE=(); V_PCT=()
V_DEVICE=(); V_DISKDEV=(); V_LUN=(); V_ISOS=()
V_AZNAME=(); V_AZID=(); V_AZSIZE=()
V_ERR=()    # per-volume collection error (empty = ok); written to the table as that volume's row

# Bound the df call so a hung mount cannot stall the whole extension run.
DF_PREFIX=""
if command -v timeout >/dev/null 2>&1; then
    DF_PREFIX="timeout 30"
fi

ROOT_SRC=""
ROOT_MM=""

collect_snapshot() {
    local line F sep i j k mnt fstype src majmin rootpath dup
    local df_out df_line D size_kb used_kb avail_kb size_h free_h used_h pct_t
    local label dev disk lun osflag
    local -a LBL_DEV=() LBL_NAME=()
    local ROOT_DISKS=""

    if [ ! -r /proc/self/mountinfo ]; then
        ERR_MSG="/proc/self/mountinfo is not readable"
        return 1
    fi

    # Local, block-device-backed filesystems only ("fixed" volumes). Pseudo/network/overlay
    # filesystems have a non-/dev source; loop (snap), optical and RAM devices are skipped.
    while IFS= read -r line; do
        set -f
        F=($line)
        set +f
        sep=-1
        for ((i = 6; i < ${#F[@]}; i++)); do
            if [ "${F[i]}" = "-" ]; then sep=$i; break; fi
        done
        [ $sep -lt 0 ] && continue

        majmin=${F[2]}
        rootpath=${F[3]}
        mnt=${F[4]}
        mnt=${mnt//\\040/ }
        mnt=${mnt//\\011/$'\t'}
        mnt=${mnt//\\012/$'\n'}
        mnt=${mnt//\\134/\\}
        fstype=${F[sep+1]}
        src=${F[sep+2]}

        if [ "$mnt" = "/" ]; then
            ROOT_SRC=$src
            ROOT_MM=$majmin
        fi

        case $src in
            /dev/loop* | /dev/sr* | /dev/ram* | /dev/zram* | /dev/fd* | /dev/nbd*) continue ;;
            /dev/*) ;;
            *) continue ;;
        esac
        case $fstype in
            squashfs | iso9660 | udf | cramfs | erofs | swap) continue ;;
        esac

        # One row per backing device: bind mounts / subvolumes of the same device collapse to
        # the real mount (the one rooted at "/") or, failing that, the first one seen.
        dup=-1
        for ((k = 0; k < ${#V_SRC[@]}; k++)); do
            if [ "${V_SRC[k]}" = "$src" ]; then dup=$k; break; fi
        done
        if [ $dup -ge 0 ]; then
            if [ "${V_ROOTFLAG[dup]}" != "/" ] && [ "$rootpath" = "/" ]; then
                V_MNT[dup]=$mnt; V_ROOTFLAG[dup]=$rootpath; V_MM[dup]=$majmin; V_FS[dup]=$fstype
            fi
            continue
        fi

        V_MNT+=("$mnt"); V_ROOTFLAG+=("$rootpath"); V_SRC+=("$src"); V_MM+=("$majmin"); V_FS+=("$fstype")
    done < /proc/self/mountinfo

    # Disk(s) backing "/" -> used for the IsOsDisk flag.
    if [ -n "$ROOT_SRC" ] && resolve_block "$ROOT_SRC" "$ROOT_MM"; then
        DISK_LIST=""
        collect_disks "$R_NAME"
        ROOT_DISKS=$DISK_LIST

        # SCSI host of the OS disk (only used by the sysfs fallback in disk_lun).
        local root_disk=${ROOT_DISKS%% *} root_real re_host='/host([0-9]+)/'
        root_real=$(readlink -f "/sys/class/block/$root_disk" 2>/dev/null)
        if [[ $root_real =~ $re_host ]]; then ROOT_HOST=${BASH_REMATCH[1]}; fi
    fi

    load_azure_lun_links

    # Filesystem labels (by-label symlinks -> real device), read once.
    for label in /dev/disk/by-label/*; do
        [ -L "$label" ] || continue
        dev=$(readlink -f "$label" 2>/dev/null)
        LBL_DEV+=("$dev")
        label=${label##*/}
        printf -v label '%b' "$label"
        LBL_NAME+=("$label")
    done

    get_azure_disk_inventory

    for ((i = 0; i < ${#V_MNT[@]}; i++)); do
        mnt=${V_MNT[i]}

        # Size / used / free via df (1K blocks, POSIX output). Used = blocks holding data (what
        # a backup would copy; reserved-for-root blocks excluded), Free = available to non-root.
        df_out=$($DF_PREFIX df -P -k -- "$mnt" 2>/dev/null)
        df_line=${df_out#*$'\n'}
        set -f
        D=($df_line)
        set +f
        size_kb=${D[1]}
        used_kb=${D[2]}
        avail_kb=${D[3]}
        V_DEVICE[i]=${V_SRC[i]}
        if ! [[ $size_kb =~ ^[0-9]+$ && $used_kb =~ ^[0-9]+$ && $avail_kb =~ ^[0-9]+$ ]]; then
            # Keep the volume and record why, so the failure is visible in the table.
            V_ERR[i]="Could not read disk usage for '$mnt' (df returned no usable values or timed out)"
            continue
        fi
        size_h=$(((size_kb * 100 + 524288) / 1048576))
        used_h=$(((used_kb * 100 + 524288) / 1048576))
        free_h=$(((avail_kb * 100 + 524288) / 1048576))
        V_SIZE[i]=""
        [ "$size_kb" -gt 0 ] && V_SIZE[i]=$(fmt_hundredths "$size_h")
        V_FREE[i]=$(fmt_hundredths "$free_h")
        V_USED[i]=$(fmt_hundredths "$used_h")
        V_PCT[i]=""
        if [ "$size_kb" -gt 0 ]; then
            # Percentage from the raw df KiB values, not the already-rounded GB figures.
            pct_t=$(((avail_kb * 1000 + size_kb / 2) / size_kb))
            V_PCT[i]=$(fmt_tenths "$pct_t")
        fi

        # Disk correlation (best effort).
        V_DEVICE[i]=${V_SRC[i]}
        V_LABEL[i]=""
        V_DISKDEV[i]=""
        V_LUN[i]=""
        V_ISOS[i]=""
        V_AZNAME[i]=""
        V_AZID[i]=""
        V_AZSIZE[i]=""

        if resolve_block "${V_SRC[i]}" "${V_MM[i]}"; then
            for ((j = 0; j < ${#LBL_DEV[@]}; j++)); do
                if [ "${LBL_DEV[j]}" = "/dev/$R_NAME" ]; then V_LABEL[i]=${LBL_NAME[j]}; break; fi
            done

            DISK_LIST=""
            collect_disks "$R_NAME"
            V_DISKDEV[i]=${DISK_LIST// /,}

            local luns="" names="" ids="" size_sum=0 size_seen=0 is_os=""
            [ -n "$ROOT_DISKS" ] && is_os=false
            for disk in $DISK_LIST; do
                osflag=0
                case " $ROOT_DISKS " in *" $disk "*) osflag=1 ;; esac
                if [ $osflag -eq 1 ]; then
                    is_os=true
                    if [ $IMDS_OK -eq 1 ]; then
                        names="${names:+$names,}$IMDS_OS_NAME"
                        ids="${ids:+$ids,}$IMDS_OS_ID"
                        if [[ $IMDS_OS_SIZE =~ ^[0-9]+$ ]]; then size_sum=$((size_sum + IMDS_OS_SIZE)); size_seen=1; fi
                    fi
                else
                    lun=$(disk_lun "$disk")
                    if [ -n "$lun" ]; then
                        luns="${luns:+$luns,}$lun"
                        if [ $IMDS_OK -eq 1 ]; then
                            for ((k = 0; k < ${#IMDS_LUN[@]}; k++)); do
                                if [ "${IMDS_LUN[k]}" = "$lun" ]; then
                                    names="${names:+$names,}${IMDS_NAME[k]}"
                                    ids="${ids:+$ids,}${IMDS_ID[k]}"
                                    if [[ ${IMDS_SIZE[k]} =~ ^[0-9]+$ ]]; then size_sum=$((size_sum + IMDS_SIZE[k])); size_seen=1; fi
                                    break
                                fi
                            done
                        fi
                    fi
                fi
            done
            V_LUN[i]=$luns
            V_ISOS[i]=$is_os
            V_AZNAME[i]=$names
            V_AZID[i]=$ids
            [ $size_seen -eq 1 ] && V_AZSIZE[i]=$size_sum
        fi
    done

    return 0
}

#endregion Snapshot

#region Main ------------------------------------------------------------------------------

StartTime=$(date '+%Y-%m-%dT%H:%M:%S')

HostName=""
if [ -r /proc/sys/kernel/hostname ]; then
    read -r HostName < /proc/sys/kernel/hostname
fi
[ -n "$HostName" ] || HostName=$(hostname 2>/dev/null)
HostName=${HostName%%.*}
HostName=$(printf '%s' "$HostName" | tr 'A-Z' 'a-z')
[ -n "$HostName" ] || HostName="unknown-host"   # RowKey must never be empty

if [ -n "$AzureVmId" ]; then
    VMName=${AzureVmId##*/}
else
    VMName=$HostName
fi

# Without these two there is nowhere to write to, so the only possible report is stderr
# (visible in the extension status). Everything after this point is logged to the table.
missing=""
[ -n "$AccountName" ] || missing="$missing AccountName"
[ -n "$SasToken" ] || missing="$missing SasToken"
if [ -n "$missing" ]; then
    echo "Missing required parameter(s):$missing" >&2
    exit 1
fi

# Table URI must be valid before anything else (mirrors the PowerShell URI check).
if ! [[ $AccountName =~ ^[a-z0-9]{3,24}$ ]] || ! [[ $TableName =~ ^[A-Za-z][A-Za-z0-9]{2,62}$ ]]; then
    echo "Constructed table URI is invalid - check -AccountName ('$AccountName') and -TableName ('$TableName')" >&2
    exit 1
fi
TableUri="https://${AccountName}.table.core.windows.net/${TableName}"

if [ -z "$HTTP_TOOL" ]; then
    echo "curl is required to reach Azure Table Storage but was not found" >&2
    exit 1
fi

# RowKey may not contain / \ # ? or control characters.
safe_key() {
    local k=$1
    k=${k//[\/\\#?]/_}
    k=${k//[[:cntrl:]]/_}
    printf '%s' "$k"
}

HostRowKey=$(safe_key "$HostName")

# Failure / informational row for the whole host (RowKey = hostname), like the PS script.
write_host_row() {
    ENT=""
    ent_str PartitionKey "$TableName"
    ent_str RowKey "$HostRowKey"
    ent_common
    ent_str EndTime "$(date '+%Y-%m-%dT%H:%M:%S')"
    ent_str Error "$1"
    write_entity "$TableName" "$HostRowKey" "{$ENT}"
}

ERROR_LOGGED=0

# Log a whole-host failure to the table, report it on stderr and stop.
fail() {
    local msg="Disk space collection failed: ${1:-unknown error}"
    msg=${msg:0:2000}                       # keep well under the table's property size limit
    echo "$msg" >&2
    ERROR_LOGGED=1
    if ! write_host_row "$msg"; then
        echo "WARNING: Could not log failure entity: $ERR_MSG" >&2
    fi
    exit 1
}

# Safety net: any non-zero exit that did not already log itself (e.g. the extension timing
# out and sending SIGTERM, or an unexpected exit) still leaves an error row behind.
on_exit() {
    local rc=$?
    if [ $rc -ne 0 ] && [ "$ERROR_LOGGED" -ne 1 ]; then
        ERROR_LOGGED=1
        write_host_row "Disk space collection failed: script terminated unexpectedly (exit code $rc)" >/dev/null 2>&1
    fi
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

if [ -z "$RunId" ]; then
    fail "Missing required parameter(s): RunId"
fi

collect_snapshot || fail "$ERR_MSG"

vol_count=${#V_MNT[@]}

if [ "$vol_count" -eq 0 ]; then
    write_host_row "No fixed volumes found" || fail "$ERR_MSG"
    exit 0
fi

# Row keys. Different mount points can sanitise to the same key (/var/lib vs /var_lib); every
# member of such a group gets a stable hash suffix so none overwrites another.
V_KEY=()
for ((i = 0; i < ${#V_MNT[@]}; i++)); do
    mnt=${V_MNT[i]}
    [ -n "$mnt" ] || continue
    if [ "$mnt" = "/" ]; then
        seed=root
    else
        seed=${mnt#/}
        seed=${seed//\//_}
    fi
    V_KEY[i]=$(safe_key "${HostName}_${seed}")
done
for ((i = 0; i < ${#V_MNT[@]}; i++)); do
    [ -n "${V_MNT[i]}" ] || continue
    for ((j = 0; j < ${#V_MNT[@]}; j++)); do
        [ "$j" -ne "$i" ] || continue
        [ -n "${V_MNT[j]}" ] || continue
        if [ "${V_KEY[j]}" = "${V_KEY[i]}" ]; then
            V_KEY[i]="${V_KEY[i]}_$(hash8 "${V_MNT[i]}")"
            break
        fi
    done
done

# One bad volume must not stop the others: record every failure, keep going, and report at
# the end. A volume whose usage could not be read still gets its own row carrying the error.
VOL_ERRORS=()
WRITE_FAILED=0

for ((i = 0; i < ${#V_MNT[@]}; i++)); do
    mnt=${V_MNT[i]}
    [ -n "$mnt" ] || continue

    RowKey=${V_KEY[i]}

    ENT=""
    ent_str PartitionKey "$TableName"
    ent_str RowKey "$RowKey"
    ent_common
    ent_str EndTime "$(date '+%Y-%m-%dT%H:%M:%S')"
    ent_str DriveLetter "$mnt"

    if [ -n "${V_ERR[i]:-}" ]; then
        ent_str FileSystem "${V_FS[i]}"
        ent_str Device "${V_DEVICE[i]}"
        ent_str Error "Disk space collection failed: ${V_ERR[i]:0:1500}"
        VOL_ERRORS+=("${V_ERR[i]}")
    else
        ent_str FileSystemLabel "${V_LABEL[i]}"
        ent_str FileSystem "${V_FS[i]}"
        ent_num SizeGB "${V_SIZE[i]}"
        ent_num UsedGB "${V_USED[i]}"
        ent_num FreeGB "${V_FREE[i]}"
        ent_num PercentFree "${V_PCT[i]}"
        ent_raw DiskNumber null
        if [[ ${V_LUN[i]} =~ ^[0-9]+$ ]]; then ent_num LUN "${V_LUN[i]}"; else ent_str LUN "${V_LUN[i]}"; fi
        ent_bool IsOsDisk "${V_ISOS[i]}"
        ent_str AzureDiskName "${V_AZNAME[i]}"
        ent_str AzureDiskResourceId "${V_AZID[i]}"
        ent_num AzureDiskSizeGB "${V_AZSIZE[i]}"
        ent_str Device "${V_DEVICE[i]}"
        ent_str DiskDevice "${V_DISKDEV[i]}"
        ent_str Error "None"
    fi

    if ! write_entity "$TableName" "$RowKey" "{$ENT}"; then
        WRITE_FAILED=1
        VOL_ERRORS+=("table write failed for '$mnt': $ERR_MSG")
    fi
done

if [ ${#VOL_ERRORS[@]} -gt 0 ]; then
    SUMMARY=""
    for e in "${VOL_ERRORS[@]}"; do
        echo "ERROR: $e" >&2
        SUMMARY="${SUMMARY:+$SUMMARY | }$e"
    done
    ERROR_LOGGED=1
    # Volume-level errors are already in their own rows. If the table itself rejected writes,
    # make one more best-effort attempt to leave a host-level summary.
    if [ $WRITE_FAILED -eq 1 ]; then
        write_host_row "Disk space collection failed: ${SUMMARY:0:1500}" >/dev/null 2>&1
    fi
    exit 1
fi

exit 0

#endregion Main
