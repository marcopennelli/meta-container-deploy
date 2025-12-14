# SPDX-License-Identifier: MIT
#
# packagegroup-containers-manifest.bb - Package group for manifest-based containers
#
# This packagegroup enables container deployment via YAML/JSON manifest files.
# Add this to IMAGE_INSTALL and configure the manifest in local.conf.
#
# Usage in local.conf:
#   CONTAINER_MANIFEST = "${TOPDIR}/../containers.yaml"
#
# Example containers.yaml:
#   containers:
#     - name: mqtt-broker
#       image: docker.io/eclipse-mosquitto:2.0
#       ports:
#         - "1883:1883"
#       restart_policy: always
#
#     - name: nginx-proxy
#       image: docker.io/nginx:alpine
#       ports:
#         - "80:80"
#         - "443:443"
#       volumes:
#         - "/var/www:/usr/share/nginx/html:ro"
#
# Then add to your image:
#   IMAGE_INSTALL += "packagegroup-containers-manifest"
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Container deployment via YAML/JSON manifest file"
DESCRIPTION = "Installs containers configured via CONTAINER_MANIFEST file"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit packagegroup

# The actual container deployment is done by containers-manifest recipe
# This packagegroup just declares dependencies
RDEPENDS:${PN} = "\
    packagegroup-container-support \
    containers-manifest \
"
