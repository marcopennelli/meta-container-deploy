# SPDX-License-Identifier: MIT
#
# container-quadlet.bbclass - Generate Podman Quadlet systemd units
#
# This class generates Podman Quadlet .container files for declarative
# systemd service management. Quadlet is the modern approach for running
# containers as systemd services (Podman 4.4+).
#
# Usage:
#   inherit container-quadlet
#
#   CONTAINER_NAME = "mqtt-broker"
#   CONTAINER_IMAGE = "docker.io/eclipse-mosquitto:2.0"
#   CONTAINER_PORTS = "1883:1883 9001:9001"
#   CONTAINER_VOLUMES = "/data/mosquitto:/mosquitto/data:rw"
#
# Optional variables:
#   CONTAINER_ENTRYPOINT - Override entrypoint
#   CONTAINER_COMMAND - Command arguments
#   CONTAINER_ENVIRONMENT - Space-separated KEY=value pairs
#   CONTAINER_NETWORK - Network mode: host, bridge, none, or custom name
#   CONTAINER_DEPENDS_ON - Space-separated list of container service names
#   CONTAINER_RESTART - Restart policy: always, on-failure, no
#   CONTAINER_USER - User to run as
#   CONTAINER_WORKING_DIR - Working directory in container
#   CONTAINER_PRIVILEGED - Set to "1" for privileged mode
#   CONTAINER_READ_ONLY - Set to "1" for read-only root filesystem
#   CONTAINER_DEVICES - Space-separated device paths (e.g., /dev/ttyUSB0)
#   CONTAINER_CAPS_ADD - Space-separated capabilities to add
#   CONTAINER_CAPS_DROP - Space-separated capabilities to drop
#   CONTAINER_SECURITY_OPTS - Space-separated security options
#   CONTAINER_LABELS - Space-separated key=value label pairs
#   CONTAINER_MEMORY_LIMIT - Memory limit (e.g., 512m, 1g)
#   CONTAINER_CPU_LIMIT - CPU limit (e.g., 0.5, 2)
#   CONTAINER_ENABLED - Set to "0" to disable auto-start (default: 1)
#   CONTAINER_POD - Pod name to join (generates Pod=<name>.pod directive)
#   CONTAINER_CGROUPS - Cgroups mode: enabled, disabled, no-conmon, split
#   CONTAINER_SDNOTIFY - SD-Notify mode: conmon, container, healthy, ignore
#   CONTAINER_TIMEZONE - Container timezone (e.g., UTC, Europe/Rome, local)
#   CONTAINER_STOP_TIMEOUT - Seconds to wait before force-killing (default: 10)
#   CONTAINER_HEALTH_CMD - Health check command
#   CONTAINER_HEALTH_INTERVAL - Interval between health checks (e.g., 30s)
#   CONTAINER_HEALTH_TIMEOUT - Timeout for health check (e.g., 10s)
#   CONTAINER_HEALTH_RETRIES - Consecutive failures before unhealthy
#   CONTAINER_HEALTH_START_PERIOD - Initialization time before checks count
#   CONTAINER_LOG_DRIVER - Log driver: journald, k8s-file, none, passthrough
#   CONTAINER_LOG_OPT - Space-separated log driver options (key=value)
#   CONTAINER_ULIMITS - Space-separated ulimits (e.g., nofile=65536:65536)
#
# Pod membership:
#   When CONTAINER_POD is set, the container becomes a member of the specified pod.
#   Pod members should NOT define CONTAINER_PORTS - ports are managed by the pod.
#   Pod members communicate via localhost within the shared network namespace.
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>
# SPDX-License-Identifier: MIT

RDEPENDS:${PN} += "podman"

# Required variables
CONTAINER_NAME ?= "${PN}"
CONTAINER_IMAGE ?= ""

# Optional configuration variables
CONTAINER_ENTRYPOINT ?= ""
CONTAINER_COMMAND ?= ""
CONTAINER_ENVIRONMENT ?= ""
CONTAINER_PORTS ?= ""
CONTAINER_VOLUMES ?= ""
CONTAINER_NETWORK ?= ""
CONTAINER_DEPENDS_ON ?= ""
CONTAINER_RESTART ?= "always"
CONTAINER_USER ?= ""
CONTAINER_WORKING_DIR ?= ""
CONTAINER_PRIVILEGED ?= ""
CONTAINER_READ_ONLY ?= ""
CONTAINER_DEVICES ?= ""
CONTAINER_CAPS_ADD ?= ""
CONTAINER_CAPS_DROP ?= ""
CONTAINER_SECURITY_OPTS ?= ""
CONTAINER_LABELS ?= ""
CONTAINER_MEMORY_LIMIT ?= ""
CONTAINER_CPU_LIMIT ?= ""
CONTAINER_ENABLED ?= "1"
CONTAINER_POD ?= ""
CONTAINER_CGROUPS ?= ""
CONTAINER_SDNOTIFY ?= ""
CONTAINER_TIMEZONE ?= ""
CONTAINER_STOP_TIMEOUT ?= ""
CONTAINER_HEALTH_CMD ?= ""
CONTAINER_HEALTH_INTERVAL ?= ""
CONTAINER_HEALTH_TIMEOUT ?= ""
CONTAINER_HEALTH_RETRIES ?= ""
CONTAINER_HEALTH_START_PERIOD ?= ""
CONTAINER_LOG_DRIVER ?= ""
CONTAINER_LOG_OPT ?= ""
CONTAINER_ULIMITS ?= ""

# Quadlet installation directory
QUADLET_DIR = "${sysconfdir}/containers/systemd"

# Validate required variables
python do_validate_quadlet() {
    container_image = d.getVar('CONTAINER_IMAGE')
    container_name = d.getVar('CONTAINER_NAME')

    if not container_image:
        bb.fatal("CONTAINER_IMAGE must be set when inheriting container-quadlet.bbclass")

    if not container_name:
        bb.fatal("CONTAINER_NAME must be set when inheriting container-quadlet.bbclass")

    # Validate restart policy
    restart = d.getVar('CONTAINER_RESTART')
    valid_restart = ['always', 'on-failure', 'no', '']
    if restart not in valid_restart:
        bb.fatal("CONTAINER_RESTART must be one of: %s" % ', '.join(valid_restart))

    # Security warnings
    if d.getVar('CONTAINER_PRIVILEGED') == '1':
        bb.warn("Container '%s' is configured for privileged mode - use with caution" % container_name)

    if d.getVar('CONTAINER_NETWORK') == 'host':
        bb.warn("Container '%s' uses host networking - network isolation disabled" % container_name)

    # Warn if pod member defines ports (pods should handle ports)
    pod = d.getVar('CONTAINER_POD')
    ports = d.getVar('CONTAINER_PORTS')
    if pod and ports:
        bb.warn("Container '%s' is a pod member but defines CONTAINER_PORTS. "
                "Ports should be defined on the pod, not individual containers." % container_name)
}
addtask validate_quadlet before do_compile

# Generate Quadlet file during compile
python do_generate_quadlet() {
    import os

    container_name = d.getVar('CONTAINER_NAME')
    container_image = d.getVar('CONTAINER_IMAGE')

    # Build Quadlet file content
    lines = []

    # [Unit] section
    lines.append("# Podman Quadlet file for " + container_name)
    lines.append("# Auto-generated by meta-container-deploy")
    lines.append("")
    lines.append("[Unit]")
    lines.append("Description=" + container_name + " container service")
    lines.append("After=network-online.target")

    # Add dependencies
    depends_on = d.getVar('CONTAINER_DEPENDS_ON')
    if depends_on:
        for dep in depends_on.split():
            lines.append("After=" + dep + ".service")
            lines.append("Requires=" + dep + ".service")

    lines.append("Wants=network-online.target")
    lines.append("")

    # [Container] section
    lines.append("[Container]")
    lines.append("Image=" + container_image)

    # Pod membership
    pod = d.getVar('CONTAINER_POD')
    if pod:
        lines.append("Pod=" + pod + ".pod")

    # Entrypoint and command
    entrypoint = d.getVar('CONTAINER_ENTRYPOINT')
    if entrypoint:
        lines.append("Exec=" + entrypoint)

    command = d.getVar('CONTAINER_COMMAND')
    if command:
        lines.append("Exec=" + command)

    # Environment variables
    environment = d.getVar('CONTAINER_ENVIRONMENT')
    if environment:
        for env in environment.split():
            if '=' in env:
                lines.append("Environment=" + env)

    # Port mappings
    ports = d.getVar('CONTAINER_PORTS')
    if ports:
        for port in ports.split():
            lines.append("PublishPort=" + port)

    # Volume mounts
    volumes = d.getVar('CONTAINER_VOLUMES')
    if volumes:
        for volume in volumes.split():
            lines.append("Volume=" + volume)

    # Device passthrough
    devices = d.getVar('CONTAINER_DEVICES')
    if devices:
        for device in devices.split():
            lines.append("AddDevice=" + device)

    # Network mode
    network = d.getVar('CONTAINER_NETWORK')
    if network:
        lines.append("Network=" + network)

    # User
    user = d.getVar('CONTAINER_USER')
    if user:
        lines.append("User=" + user)

    # Working directory
    working_dir = d.getVar('CONTAINER_WORKING_DIR')
    if working_dir:
        lines.append("WorkingDir=" + working_dir)

    # Labels
    labels = d.getVar('CONTAINER_LABELS')
    if labels:
        for label in labels.split():
            if '=' in label:
                lines.append("Label=" + label)

    # Security options
    privileged = d.getVar('CONTAINER_PRIVILEGED')
    if privileged == '1':
        lines.append("SecurityLabelDisable=true")

    security_opts = d.getVar('CONTAINER_SECURITY_OPTS')
    if security_opts:
        for opt in security_opts.split():
            lines.append("SecurityOpt=" + opt)

    # Capabilities
    caps_add = d.getVar('CONTAINER_CAPS_ADD')
    if caps_add:
        for cap in caps_add.split():
            lines.append("AddCapability=" + cap)

    caps_drop = d.getVar('CONTAINER_CAPS_DROP')
    if caps_drop:
        for cap in caps_drop.split():
            lines.append("DropCapability=" + cap)

    # Read-only root filesystem
    read_only = d.getVar('CONTAINER_READ_ONLY')
    if read_only == '1':
        lines.append("ReadOnly=true")

    # Resource limits (via PodmanArgs)
    memory_limit = d.getVar('CONTAINER_MEMORY_LIMIT')
    if memory_limit:
        lines.append("PodmanArgs=--memory " + memory_limit)

    cpu_limit = d.getVar('CONTAINER_CPU_LIMIT')
    if cpu_limit:
        lines.append("PodmanArgs=--cpus " + cpu_limit)

    # Cgroups mode
    cgroups = d.getVar('CONTAINER_CGROUPS')
    if cgroups:
        lines.append("PodmanArgs=--cgroups " + cgroups)

    # SD-Notify mode
    sdnotify = d.getVar('CONTAINER_SDNOTIFY')
    if sdnotify:
        lines.append("Notify=" + ("true" if sdnotify == "container" else "false"))
        if sdnotify != "conmon":
            lines.append("PodmanArgs=--sdnotify " + sdnotify)

    # Timezone
    timezone = d.getVar('CONTAINER_TIMEZONE')
    if timezone:
        lines.append("Timezone=" + timezone)

    # Health check options
    health_cmd = d.getVar('CONTAINER_HEALTH_CMD')
    if health_cmd:
        lines.append("HealthCmd=" + health_cmd)

    health_interval = d.getVar('CONTAINER_HEALTH_INTERVAL')
    if health_interval:
        lines.append("HealthInterval=" + health_interval)

    health_timeout = d.getVar('CONTAINER_HEALTH_TIMEOUT')
    if health_timeout:
        lines.append("HealthTimeout=" + health_timeout)

    health_retries = d.getVar('CONTAINER_HEALTH_RETRIES')
    if health_retries:
        lines.append("HealthRetries=" + health_retries)

    health_start_period = d.getVar('CONTAINER_HEALTH_START_PERIOD')
    if health_start_period:
        lines.append("HealthStartPeriod=" + health_start_period)

    # Log driver
    log_driver = d.getVar('CONTAINER_LOG_DRIVER')
    if log_driver:
        lines.append("LogDriver=" + log_driver)

    # Log options
    log_opt = d.getVar('CONTAINER_LOG_OPT')
    if log_opt:
        for opt in log_opt.split():
            if '=' in opt:
                lines.append("PodmanArgs=--log-opt " + opt)

    # Ulimits
    ulimits = d.getVar('CONTAINER_ULIMITS')
    if ulimits:
        for ulimit in ulimits.split():
            lines.append("Ulimit=" + ulimit)

    lines.append("")

    # [Service] section
    lines.append("[Service]")
    restart = d.getVar('CONTAINER_RESTART') or 'always'
    lines.append("Restart=" + restart)
    lines.append("TimeoutStartSec=900")

    # Stop timeout
    stop_timeout = d.getVar('CONTAINER_STOP_TIMEOUT')
    if stop_timeout:
        lines.append("TimeoutStopSec=" + stop_timeout)

    lines.append("")

    # [Install] section
    lines.append("[Install]")
    enabled = d.getVar('CONTAINER_ENABLED')
    if enabled != '0':
        lines.append("WantedBy=multi-user.target")
    else:
        lines.append("# Container disabled - uncomment to enable")
        lines.append("# WantedBy=multi-user.target")

    # Write the Quadlet file
    workdir = d.getVar('WORKDIR')
    quadlet_file = os.path.join(workdir, container_name + ".container")

    with open(quadlet_file, 'w') as f:
        f.write('\n'.join(lines))
        f.write('\n')

    bb.note("Generated Quadlet file: " + quadlet_file)
}

addtask do_generate_quadlet after do_configure before do_compile

# Install Quadlet file (appends to do_install)
do_install:append() {
    CONTAINER_NAME="${CONTAINER_NAME}"

    install -d ${D}${QUADLET_DIR}
    install -m 0644 ${WORKDIR}/${CONTAINER_NAME}.container \
        ${D}${QUADLET_DIR}/
}

# Package files - use :append to allow combining with other bbclasses
FILES:${PN}:append = " ${QUADLET_DIR}/${CONTAINER_NAME}.container"
