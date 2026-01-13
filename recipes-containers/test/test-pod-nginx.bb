# SPDX-License-Identifier: MIT
#
# Test pod member: nginx container
#
# This container is a member of test-pod and communicates
# with other pod members via localhost.
#
# Copyright (c) 2026 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Nginx container as test-pod member"
DESCRIPTION = "Nginx web server running as part of test-pod"
HOMEPAGE = "https://nginx.org/"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit container-image container-quadlet

CONTAINER_IMAGE = "docker.io/library/nginx:alpine"
CONTAINER_NAME = "test-pod-nginx"

# This container is a member of test-pod
# Ports are handled by the pod, not the container
CONTAINER_POD = "test-pod"

CONTAINER_RESTART = "always"

# Depends on the pod recipe
RDEPENDS:${PN} += "test-pod"
