#!/bin/sh
# SPDX-License-Identifier: MIT
#
# container-import.sh - Import all preloaded container images into Podman storage
#
# This script is executed at first boot to import OCI container images
# that were pulled at build time into Podman's container storage.
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>

set -e

PRELOAD_DIR="/var/lib/containers/preloaded"
IMPORT_SCRIPT_DIR="/etc/containers/import.d"
LOG_TAG="container-import"

log_info() {
    logger -t "$LOG_TAG" -p info "$1"
    echo "[INFO] $1"
}

log_error() {
    logger -t "$LOG_TAG" -p err "$1"
    echo "[ERROR] $1" >&2
}

# Check if import scripts directory exists
if [ ! -d "$IMPORT_SCRIPT_DIR" ]; then
    log_info "No container import scripts found in $IMPORT_SCRIPT_DIR"
    exit 0
fi

# Find and execute all import scripts
IMPORT_COUNT=0
FAIL_COUNT=0

for script in "$IMPORT_SCRIPT_DIR"/*.sh; do
    [ -f "$script" ] || continue

    container_name=$(basename "$script" .sh)
    log_info "Importing container: $container_name"

    if sh "$script"; then
        log_info "Successfully imported container: $container_name"
        IMPORT_COUNT=$((IMPORT_COUNT + 1))
    else
        log_error "Failed to import container: $container_name"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

log_info "Container import complete: $IMPORT_COUNT succeeded, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
