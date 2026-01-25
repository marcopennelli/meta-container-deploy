#!/bin/sh
# SPDX-License-Identifier: MIT
#
# rootfs-expand.sh - Expand root filesystem to use all available space
#
# This script automatically expands the root partition and filesystem
# on first boot to utilize the full SD card/storage capacity.
#
# Copyright (c) 2026 Marco Pennelli <marco.pennelli@technosec.net>

set -e

MARKER_FILE="/var/lib/rootfs-expand/.expanded"
LOG_TAG="rootfs-expand"

log_info() {
    logger -t "$LOG_TAG" -p info "$1"
    echo "[INFO] $1"
}

log_error() {
    logger -t "$LOG_TAG" -p err "$1"
    echo "[ERROR] $1" >&2
}

# Check if already expanded
if [ -f "$MARKER_FILE" ]; then
    log_info "Root filesystem already expanded, skipping"
    exit 0
fi

# Find root device and partition
ROOT_PART=$(findmnt -n -o SOURCE /)
if [ -z "$ROOT_PART" ]; then
    log_error "Could not determine root partition"
    exit 1
fi

log_info "Root partition: $ROOT_PART"

# Extract device and partition number
# Handle /dev/mmcblk0p2, /dev/sda2, /dev/nvme0n1p2 formats
case "$ROOT_PART" in
    /dev/mmcblk*p* | /dev/nvme*n*p*)
        ROOT_DEV=$(echo "$ROOT_PART" | sed 's/p[0-9]*$//')
        PART_NUM=$(echo "$ROOT_PART" | sed 's/.*p//')
        ;;
    /dev/sd* | /dev/vd*)
        ROOT_DEV=$(echo "$ROOT_PART" | sed 's/[0-9]*$//')
        PART_NUM=$(echo "$ROOT_PART" | sed 's/.*[a-z]//')
        ;;
    *)
        log_error "Unsupported device format: $ROOT_PART"
        exit 1
        ;;
esac

log_info "Root device: $ROOT_DEV, partition number: $PART_NUM"

# Get current and max partition sizes
# Use head -1 to get only the device/partition size (not children)
# Use tr to remove any trailing whitespace
CURRENT_SIZE=$(lsblk -b -n -d -o SIZE "$ROOT_PART" 2>/dev/null | tr -d '[:space:]')
DEVICE_SIZE=$(lsblk -b -n -d -o SIZE "$ROOT_DEV" 2>/dev/null | tr -d '[:space:]')

# Ensure we have valid numbers, default to 0 if empty
CURRENT_SIZE=${CURRENT_SIZE:-0}
DEVICE_SIZE=${DEVICE_SIZE:-0}

log_info "Current partition size: $CURRENT_SIZE bytes"
log_info "Device size: $DEVICE_SIZE bytes"

# Check if expansion is needed (leave 10% margin)
# Use shell arithmetic instead of bc for portability
# Ensure DEVICE_SIZE is non-zero to avoid division issues
if [ "$DEVICE_SIZE" -eq 0 ] 2>/dev/null; then
    log_error "Could not determine device size"
    exit 1
fi

THRESHOLD=$((DEVICE_SIZE * 9 / 10))
if [ "$CURRENT_SIZE" -ge "$THRESHOLD" ] 2>/dev/null; then
    log_info "Partition already at maximum size, no expansion needed"
    mkdir -p "$(dirname "$MARKER_FILE")"
    touch "$MARKER_FILE"
    exit 0
fi

# Expand partition using growpart if available
if command -v growpart >/dev/null 2>&1; then
    log_info "Expanding partition using growpart..."
    if growpart "$ROOT_DEV" "$PART_NUM"; then
        log_info "Partition expanded successfully"
    else
        # growpart returns 1 if partition is already at max size
        GROW_RC=$?
        if [ "$GROW_RC" -eq 1 ]; then
            log_info "Partition already at maximum size"
        else
            log_error "growpart failed with exit code $GROW_RC"
            exit 1
        fi
    fi
elif command -v sfdisk >/dev/null 2>&1; then
    # Fallback to sfdisk
    log_info "Expanding partition using sfdisk..."
    echo ",+" | sfdisk -N "$PART_NUM" "$ROOT_DEV" --no-reread 2>/dev/null || true
    partprobe "$ROOT_DEV" 2>/dev/null || true
else
    log_error "Neither growpart nor sfdisk available for partition expansion"
    exit 1
fi

# Resize the filesystem
log_info "Resizing filesystem..."

# Detect filesystem type
FS_TYPE=$(lsblk -n -o FSTYPE "$ROOT_PART" 2>/dev/null || blkid -s TYPE -o value "$ROOT_PART" 2>/dev/null)

case "$FS_TYPE" in
    ext2|ext3|ext4)
        log_info "Detected ext filesystem, using resize2fs"
        if resize2fs "$ROOT_PART"; then
            log_info "Filesystem resized successfully"
        else
            log_error "resize2fs failed"
            exit 1
        fi
        ;;
    btrfs)
        log_info "Detected btrfs filesystem"
        if btrfs filesystem resize max /; then
            log_info "Filesystem resized successfully"
        else
            log_error "btrfs resize failed"
            exit 1
        fi
        ;;
    xfs)
        log_info "Detected XFS filesystem"
        if xfs_growfs /; then
            log_info "Filesystem resized successfully"
        else
            log_error "xfs_growfs failed"
            exit 1
        fi
        ;;
    f2fs)
        log_info "Detected F2FS filesystem"
        if resize.f2fs "$ROOT_PART"; then
            log_info "Filesystem resized successfully"
        else
            log_error "resize.f2fs failed"
            exit 1
        fi
        ;;
    *)
        log_error "Unsupported filesystem type: $FS_TYPE"
        exit 1
        ;;
esac

# Create marker file to prevent re-running
mkdir -p "$(dirname "$MARKER_FILE")"
touch "$MARKER_FILE"

# Log final size
NEW_SIZE=$(df -h / | tail -1 | awk '{print $2}')
log_info "Root filesystem expansion complete. New size: $NEW_SIZE"

exit 0
