# SPDX-License-Identifier: MIT
#
# packagegroup-containers-localconf.bb - Package group for local.conf containers
#
# This packagegroup enables container deployment via local.conf configuration.
# Add this to IMAGE_INSTALL and configure containers in local.conf.
#
# Usage in local.conf:
#   CONTAINERS = "mqtt-broker nginx-proxy"
#   CONTAINER_mqtt_broker_IMAGE = "docker.io/eclipse-mosquitto:2.0"
#   CONTAINER_mqtt_broker_PORTS = "1883:1883"
#   ...
#
# Then add to your image:
#   IMAGE_INSTALL += "packagegroup-containers-localconf"
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Container deployment via local.conf configuration"
DESCRIPTION = "Installs containers configured via CONTAINERS variable in local.conf"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit packagegroup

# The actual container deployment is done by containers-localconf recipe
# This packagegroup just declares dependencies
RDEPENDS:${PN} = "\
    packagegroup-container-support \
    containers-localconf \
"
