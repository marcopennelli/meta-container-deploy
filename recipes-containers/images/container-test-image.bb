# SPDX-License-Identifier: MIT
#
# container-test-image.bb - Test image for validating meta-container-deploy
#
# This image provides a minimal system with Podman and container support
# to validate the meta-container-deploy layer functionality.
#
# IMPORTANT: This image requires systemd for Quadlet support.
# Add to local.conf:
#   DISTRO_FEATURES:append = " systemd usrmerge virtualization"
#   DISTRO_FEATURES_BACKFILL_CONSIDERED:append = " sysvinit"
#   VIRTUAL-RUNTIME_init_manager = "systemd"
#   VIRTUAL-RUNTIME_initscripts = "systemd-compat-units"
#
# Build with: bitbake container-test-image
# Run with: runqemu qemux86-64 nographic
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Test image for meta-container-deploy validation"
DESCRIPTION = "A minimal image with Podman and preloaded containers \
for testing the meta-container-deploy layer."
HOMEPAGE = "https://github.com/meta-container-deploy/meta-container-deploy"
LICENSE = "MIT"

inherit core-image

# Base image features
IMAGE_FEATURES += " \
    ssh-server-openssh \
    debug-tweaks \
"

# Core packages for container support
IMAGE_INSTALL += " \
    packagegroup-container-support \
    test-container \
    kernel-modules \
"

# Additional useful packages for testing
IMAGE_INSTALL += " \
    coreutils \
    util-linux \
    bash \
"

# Ensure adequate rootfs size for containers
IMAGE_ROOTFS_EXTRA_SPACE = "1048576"

# Set a reasonable default hostname
hostname:pn-base-files = "container-test"
