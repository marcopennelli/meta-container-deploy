# SPDX-License-Identifier: MIT
#
# Test network recipe for meta-container-deploy layer validation
#
# This recipe demonstrates network support by creating a custom
# bridge network with a defined subnet and gateway.
#
# Copyright (c) 2026 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Test network for layer validation"
DESCRIPTION = "A test bridge network to verify network Quadlet support"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit container-network

NETWORK_NAME = "test-net"
NETWORK_DRIVER = "bridge"
NETWORK_SUBNET = "10.89.0.0/24"
NETWORK_GATEWAY = "10.89.0.1"
