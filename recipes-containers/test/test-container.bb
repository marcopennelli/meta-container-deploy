# SPDX-License-Identifier: MIT
#
# Test container recipe for meta-container-deploy layer validation
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Test nginx container for layer validation"
DESCRIPTION = "A nginx web server container to verify meta-container-deploy functionality"
HOMEPAGE = "https://nginx.org/"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit container-image container-quadlet

CONTAINER_IMAGE = "docker.io/library/nginx:alpine"
CONTAINER_NAME = "test-nginx"

# Expose port 80 for testing
CONTAINER_PORTS = "8080:80"
CONTAINER_RESTART = "always"
