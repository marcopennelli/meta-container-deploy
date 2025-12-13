# SPDX-License-Identifier: MIT
#
# container-import.bb - First-boot container image import service
#
# This recipe provides a systemd service that imports preloaded OCI container
# images into Podman storage on first boot.
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Container image import service for preloaded OCI images"
DESCRIPTION = "Systemd service that imports preloaded container images into Podman storage at first boot"
HOMEPAGE = "https://github.com/meta-container-deploy/meta-container-deploy"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://container-import.sh"

RDEPENDS:${PN} = "podman"

inherit systemd

SYSTEMD_AUTO_ENABLE = "enable"
SYSTEMD_SERVICE:${PN} = "container-import.service"

do_install() {
    # Install the import script
    install -d ${D}${libexecdir}
    install -m 0755 ${WORKDIR}/container-import.sh ${D}${libexecdir}/

    # Create directories for import scripts and preloaded images
    install -d ${D}${sysconfdir}/containers/import.d
    install -d ${D}/var/lib/containers/preloaded
    install -d ${D}/var/lib/containers/preloaded/.imported

    # Install systemd service
    install -d ${D}${systemd_system_unitdir}
    cat > ${D}${systemd_system_unitdir}/container-import.service << 'EOF'
[Unit]
Description=Import preloaded container images into Podman storage
DefaultDependencies=no
After=local-fs.target
Before=podman.service
ConditionDirectoryNotEmpty=/etc/containers/import.d

[Service]
Type=oneshot
ExecStart=/usr/libexec/container-import.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

FILES:${PN} = "\
    ${libexecdir}/container-import.sh \
    ${sysconfdir}/containers/import.d \
    /var/lib/containers/preloaded \
    ${systemd_system_unitdir}/container-import.service \
"

# Allow empty directories
ALLOW_EMPTY:${PN} = "1"
