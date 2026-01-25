# SPDX-License-Identifier: MIT
#
# rootfs-expand.bb - First-boot root filesystem expansion
#
# This recipe provides a systemd service that automatically expands the
# root partition and filesystem to utilize the full storage capacity
# on first boot. This is particularly useful for SD card deployments
# where the image size is smaller than the target media.
#
# Supported filesystems: ext2, ext3, ext4, btrfs, xfs, f2fs
# Supported devices: SD cards (mmcblk), NVMe, SATA/USB drives
#
# Usage in local.conf:
#   IMAGE_INSTALL:append = " rootfs-expand"
#
# Or via ROOTFS_EXPAND = "1" when using container-image class
#
# Copyright (c) 2026 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Automatic root filesystem expansion on first boot"
DESCRIPTION = "Systemd service that expands the root partition and filesystem \
to utilize all available storage space on first boot. Useful for SD card \
deployments where a smaller image needs to use the full card capacity."
HOMEPAGE = "https://github.com/technosec/meta-container-deploy"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/files/common-licenses/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://rootfs-expand.sh \
    file://rootfs-expand.service \
"

S = "${WORKDIR}"

# Runtime dependencies for partition and filesystem operations
RDEPENDS:${PN} = " \
    util-linux-lsblk \
    util-linux-findmnt \
    util-linux-sfdisk \
    e2fsprogs-resize2fs \
"

# Optional packages for additional functionality
# partx is more reliable than partprobe for mounted partitions
RRECOMMENDS:${PN} = " \
    util-linux-partprobe \
    util-linux-partx \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "rootfs-expand.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    # Install the expansion script
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/rootfs-expand.sh ${D}${sbindir}/rootfs-expand

    # Install systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/rootfs-expand.service ${D}${systemd_system_unitdir}/

    # Create marker directory
    install -d ${D}${localstatedir}/lib/rootfs-expand
}

FILES:${PN} = " \
    ${sbindir}/rootfs-expand \
    ${systemd_system_unitdir}/rootfs-expand.service \
    ${localstatedir}/lib/rootfs-expand \
"
