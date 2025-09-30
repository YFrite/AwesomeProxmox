#!/usr/bin/env bash
#
# pct-shrink-lv.sh
# Usage: sudo ./pct-shrink-lv.sh <CTID> <TARGET_SIZE> [--yes] [--snapshot <SNAP_SIZE>]
# Example: sudo ./pct-shrink-lv.sh 999 10G --yes --snapshot 1G

set -euo pipefail

print_usage() {
    cat <<EOF
    Usage: $0 <CTID> <TARGET_SIZE> [--yes] [--snapshot <SNAP_SIZE>]
        CTID               - LXC container id (e.g. 999)
        TARGET_SIZE        - target size for LV and filesystem (e.g. 10G, 10240M)
        --yes              - don't ask interactive confirmation
        --snapshot X       - create LVM snapshot of size X (e.g. 1G) before shrinking
EOF
}

if [[ $# -lt 2 ]]; then
    print_usage
    exit 1
fi

CTID="$1"
TARGET_SIZE="$2"
shift 2

AUTO_YES=0
SNAP_OPT=""
SNAP_SIZE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) AUTO_YES=1; shift ;;
        --snapshot) SNAP_SIZE="$2"; SNAP_OPT="--snapshot"; shift 2 ;;
        -h|--help) print_usage; exit 0 ;;
       *) echo "Unknown arg: $1"; print_usage; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# Check container exists
if ! pct status "$CTID" &>/dev/null; then
    echo "Container $CTID not found (pct status failed). Run 'pct list' to inspect."
    exit 1
fi

echo "Preparing to shrink contaier $CTID to $TARGET_SIZE"

if [[ $AUTO_YES -eq 0 ]]; then
    read -rp "Proceed? This operation is potentially destructive. Type YES to continue: " CONF
    if [[ "$CONF" != "YES" ]]; then
        echo "Aborted by user."
        exit 1
    fi
fi

# Stop container if running
STATUS="$(pct status "$CTID" | awk '{print $2}')"
if [[ "$STATUS" == "running" ]]; then
    echo "Stoping container $CTID..."
    pct stop "$CTID" || { echo "Failed to stop container"; exit 1; }
else
    echo "Container $CTID is not running (status: $STATUS)"
fi

# Find LV path for vm-<CTID>-disk-0 using lvdisplay fallback parsing
LV_NAME="vm-${CTID}-disk-0"
echo "Searching for LV named $LV_NAME..."
LV_PATH=""

if command -v lvs &>/dev/null; then
    LV_PATH=$(lvs --noheadings -o lv_name,vg_name,lv_path 2>/dev/null | awk -v name="$LV_NAME" '$1==name {print $3}')
fi

if [[ -z "$LV_PATH" ]]; then
    LV_PATH=$(lvdisplay 2>/dev/null | awk -v name="$LV_NAME" '
    /LV Name/ {namecur=$3}
    /LV Path/ {path=$3; if (namecur==name) print path}
    ')
fi

if [[ -z "$LV_PATH" ]]; then
    echo "Could not find LV for $LV_NAME. Check lvdisplay output manually."
    exit 1
fi

echo "Found LV: $LV_PATH"

# Save metadata and config backups
TS=$(date +"%Y%m%d-%H%M%S")
BACKUP_DIR="/root/shrink-backups-${TS}"
mkdir -p "$BACKUP_DIR"
echo "Saving backups to $BACKUP_DIR..."

lvdisplay "$LV_PATH" > "$BACKUP_DIR/lvdisplay-$(basename "LV_PATH").txt" 2>&1 || true

CT_CONF="/etc/pve/lxc/${CTID}.conf"
if [[ -f "$CT_CONF" ]]; then
    cp -a "$CT_CONF" "$BACKUP_DIR/$(basename "CT_CONF").bak"
    echo "Copied config $CT_CONF -> $BACKUP_DIR"
else
    echo "Warning: container config $CT_CONF not found."
fi

# Optional snapshot
SNAP_NAME=""
if [[ -n "$SNAP_SIZE" ]]; then
    VG_NAME=$(lvs --noheadings -o vg_name --units g --nosuffix "$LV_PATH" 2>/dev/null | awk '{print $1}' || true)
    if [[ -z "$VG_NAME" ]]; then
        VG_NAME=$(echo "$LV_PATH" | awk -F'/' '{print $(NF-1)}')
    fi
    SNAP_NAME="${LV_NAME}-pre-shrink-snap-${TS}"
    echo "Creating snapshot $VG_NAME/$SNAP_NAME of $LV_PATH size $SNAP_SIZE..."
    if ! lvcreate -L "$SNAP_SIZE" -s -n "$SNAP_NAME" "$LV_PATH"; then
        echo "Snapshot creation failed. Aborting."
        exit 1
    fi
    echo "Snapshot created: /dev/$VG_NAME/$SNAP_NAME"
    echo "/dev/$VG_NAME/$SNAP_NAME" > "$BACKUP_DIR/snapshot-path.txt"
fi

echo "Running e2fsck -fy on $LV_PATH..."
if ! e2fsck -fy "$LV_PATH"; then
    echo "e2fsck failed. Aborting."
    exit 1
fi

echo "Resizing filesystem on $LV_PATH to $TARGET_SIZE..."
if ! resize2fs "$LV_PATH" "$TARGET_SIZE"; then
    echo "resize2fs failed. Aborting."
    exit 1
fi


echo "Reducing LV $LV_PATH to $TARGET_SIZE..."
if ! lvreduce -L "$TARGET_SIZE" "$LV_PATH" -f; then
    echo "lvreduce failed. Aborting."
    exit 1
fi

echo "Post-reduce lvdisplay:"
lvdisplay "$LV_PATH" | sed -n '1,8p' || true

# Update /etc/pve/lxc/<CTID>.conf rootfs size field
if [[ -f "$CT_CONF" ]]; then
    echo "Updating conf $CT_CONF rootfs size -> $TARGET_SIZE (backup created)..."
    cp -a "$CT_CONF" "${CT_CONF}.bak-${TS}"

    awk -v lvname="$LV_NAME" -v tgt="$TARGET_SIZE" '
        /^rootfs:/ && index($0, lvname) {
            if (index($0, lvname)) {
                gsub(/size=[^,[:space:]]+/, "size=" tgt)
            }
        }
        {print}
    ' "$CT_CONF" > "${CT_CONF}.tmp" && mv "${CT_CONF}.tmp" "$CT_CONF"
    echo "Config updated. Original saved as ${CT_CONF}.bak-${TS}"
else
    echo "Config $CT_CONF not found - skipping conf update."
fi

echo "Starting container $CTID..."
if ! pct start "$CTID"; then
    echo "Failed to start container $CTID. Check logs and restore from backup/snapshot if necessary."
    exit 1
fi

echo "Container $CTID start. Shrink operation completed."
echo "Backups are in: $BACKUP_DIR"
if [[ -n "$SNAP_NAME" ]]; then
    echo "Snapshot created: /dev/${VG_NAME}/${SNAP_NAME} (consider removing it when you're satisfied: lvremove /dev/${VG_NAME}/${SNAP_NAME})"
fi

exit 0
