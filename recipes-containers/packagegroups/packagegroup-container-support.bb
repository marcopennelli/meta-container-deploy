# SPDX-License-Identifier: MIT
#
# packagegroup-container-support.bb - Base container support packagegroup
#
# This packagegroup provides all the base packages required for container
# support with Podman and Quadlet integration.
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Container support packagegroup for Podman and Quadlet"
DESCRIPTION = "Provides base packages for container deployment including Podman, \
skopeo for image management, and the container-import service for \
preloaded container images."
HOMEPAGE = "https://github.com/meta-container-deploy/meta-container-deploy"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit packagegroup

RDEPENDS:${PN} = "\
    podman \
    skopeo \
    container-import \
"

# Optional: Include podman-compose for multi-container deployments
RRECOMMENDS:${PN} = "\
    podman-compose \
"
