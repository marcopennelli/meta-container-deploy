# SPDX-License-Identifier: MIT
#
# containers-localconf.bb - Deploy containers configured in local.conf
#
# This recipe pulls and installs containers configured via the CONTAINERS
# variable in local.conf. It's the actual worker recipe that does container
# deployment - use packagegroup-containers-localconf as the entry point.
#
# Usage in local.conf:
#   CONTAINERS = "mqtt-broker nginx-proxy"
#   CONTAINER_mqtt_broker_IMAGE = "docker.io/eclipse-mosquitto:2.0"
#   CONTAINER_mqtt_broker_PORTS = "1883:1883"
#   ...
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>

SUMMARY = "Container deployment from local.conf configuration"
DESCRIPTION = "Pulls and installs containers configured via CONTAINERS variable"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit container-localconf

# Allow empty package if no containers configured
ALLOW_EMPTY:${PN} = "1"
