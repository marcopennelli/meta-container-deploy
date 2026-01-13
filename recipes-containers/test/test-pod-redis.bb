# SPDX-License-Identifier: MIT
#
# Test pod member: redis container
#
# This container is a member of test-pod and can be accessed
# by other pod members via localhost:6379.
#
# Copyright (c) 2026 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Redis container as test-pod member"
DESCRIPTION = "Redis key-value store running as part of test-pod"
HOMEPAGE = "https://redis.io/"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit container-image container-quadlet

CONTAINER_IMAGE = "docker.io/library/redis:alpine"
CONTAINER_NAME = "test-pod-redis"

# This container is a member of test-pod
# Ports are handled by the pod, not the container
CONTAINER_POD = "test-pod"

CONTAINER_RESTART = "always"

# Depends on the pod recipe
RDEPENDS:${PN} += "test-pod"
