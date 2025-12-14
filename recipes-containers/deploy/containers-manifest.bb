# SPDX-License-Identifier: MIT
#
# containers-manifest.bb - Deploy containers from YAML/JSON manifest
#
# This recipe pulls and installs containers configured via a manifest file.
# It's the actual worker recipe that does container deployment - use
# packagegroup-containers-manifest as the entry point.
#
# Usage in local.conf:
#   CONTAINER_MANIFEST = "${TOPDIR}/../containers.yaml"
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Container deployment from manifest file"
DESCRIPTION = "Pulls and installs containers configured via CONTAINER_MANIFEST"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit container-manifest

# Allow empty package if no manifest configured
ALLOW_EMPTY:${PN} = "1"
