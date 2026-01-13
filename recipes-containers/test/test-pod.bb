# SPDX-License-Identifier: MIT
#
# Test pod recipe for meta-container-deploy layer validation
#
# This recipe demonstrates pod support by creating a pod with
# nginx frontend and a simple backend container.
#
# Copyright (c) 2026 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Test pod for layer validation"
DESCRIPTION = "A test pod with nginx and redis to verify pod support"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit container-pod

POD_NAME = "test-pod"

# Pod handles all port mappings for member containers
POD_PORTS = "8080:80 6379:6379"
POD_NETWORK = "bridge"
POD_HOSTNAME = "test-pod"
