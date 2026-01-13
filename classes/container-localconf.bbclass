# SPDX-License-Identifier: MIT
#
# container-localconf.bbclass - Configure containers via local.conf variables
#
# This class enables container configuration directly in local.conf without
# requiring individual recipe files. It's designed for dynamic container
# provisioning systems like Fucinas that generate local.conf at build time.
#
# Usage in local.conf:
#   CONTAINERS = "mqtt-broker nginx-proxy"
#
#   CONTAINER_mqtt-broker_IMAGE = "docker.io/eclipse-mosquitto:2.0"
#   CONTAINER_mqtt-broker_PORTS = "1883:1883 9001:9001"
#   CONTAINER_mqtt-broker_VOLUMES = "/data/mosquitto:/mosquitto/data:rw"
#   CONTAINER_mqtt-broker_RESTART = "always"
#
#   CONTAINER_nginx-proxy_IMAGE = "docker.io/nginx:alpine"
#   CONTAINER_nginx-proxy_PORTS = "80:80 443:443"
#   CONTAINER_nginx-proxy_ENVIRONMENT = "NGINX_WORKER=4"
#
# Usage in image recipe:
#   inherit container-localconf
#
# Configuration variables per container (CONTAINER_<name>_<VAR>):
#   IMAGE (required) - Container image reference
#   PORTS - Port mappings (space-separated, e.g., "8080:80 443:443")
#   VOLUMES - Volume mounts (space-separated, e.g., "/host:/container:rw")
#   ENVIRONMENT - Environment variables (space-separated KEY=value)
#   NETWORK - Network mode: host, bridge, none, or custom name
#   RESTART - Restart policy: always, on-failure, no (default: always)
#   USER - User to run as
#   WORKING_DIR - Working directory in container
#   DEVICES - Device paths (space-separated)
#   CAPS_ADD - Capabilities to add (space-separated)
#   CAPS_DROP - Capabilities to drop (space-separated)
#   PRIVILEGED - Set to "1" for privileged mode
#   READ_ONLY - Set to "1" for read-only root filesystem
#   MEMORY_LIMIT - Memory limit (e.g., 512m, 1g)
#   CPU_LIMIT - CPU limit (e.g., 0.5, 2)
#   ENABLED - Set to "0" to disable auto-start (default: 1)
#   LABELS - Labels (space-separated key=value)
#   DEPENDS_ON - Container dependencies (space-separated names)
#   ENTRYPOINT - Override entrypoint
#   COMMAND - Command arguments
#   PULL_POLICY - Pull policy: always, missing, never (default: missing)
#   DIGEST - Pin to specific digest for reproducibility
#   POD - Pod name to join (container becomes a pod member)
#
# Pod configuration (PODS variable + POD_<name>_<VAR>):
#   PODS - Space-separated list of pod names to create
#   POD_<name>_PORTS - Port mappings for the pod
#   POD_<name>_NETWORK - Network mode for the pod
#   POD_<name>_VOLUMES - Shared volumes for pod containers
#   POD_<name>_LABELS - Labels for the pod
#   POD_<name>_DNS - DNS servers for the pod
#   POD_<name>_HOSTNAME - Hostname for the pod
#   POD_<name>_ENABLED - Set to "0" to disable pod auto-start
#
# Example with pods:
#   PODS = "myapp"
#   POD_myapp_PORTS = "8080:8080 8081:8081"
#   POD_myapp_NETWORK = "bridge"
#
#   CONTAINERS = "myapp-backend myapp-frontend"
#   CONTAINER_myapp_backend_IMAGE = "myregistry/backend:v1"
#   CONTAINER_myapp_backend_POD = "myapp"
#   CONTAINER_myapp_frontend_IMAGE = "myregistry/frontend:v1"
#   CONTAINER_myapp_frontend_POD = "myapp"
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>
# SPDX-License-Identifier: MIT

# List of containers to configure
CONTAINERS ?= ""

# List of pods to configure
PODS ?= ""

# Include base dependencies
DEPENDS += "skopeo-native"
RDEPENDS:${PN} += "podman container-import"

# OCI storage locations (from container-image.bbclass)
CONTAINER_PRELOAD_DIR = "/var/lib/containers/preloaded"
CONTAINER_IMPORT_MARKER_DIR = "/var/lib/containers/preloaded/.imported"
QUADLET_DIR = "${sysconfdir}/containers/systemd"

# Map Yocto architectures to OCI architectures
def get_oci_arch(d):
    """Map TARGET_ARCH to OCI platform architecture."""
    arch_map = {
        'aarch64': 'arm64',
        'arm': 'arm',
        'x86_64': 'amd64',
        'i686': '386',
        'i586': '386',
        'riscv64': 'riscv64',
        'riscv32': 'riscv32',
        'mips': 'mips',
        'mips64': 'mips64',
        'powerpc': 'ppc',
        'powerpc64': 'ppc64',
        'powerpc64le': 'ppc64le',
    }
    target_arch = d.getVar('TARGET_ARCH')
    return arch_map.get(target_arch, target_arch)

def get_container_var(d, container_name, var_name, default=''):
    """Get a container-specific variable with fallback to default."""
    # Sanitize container name for BitBake variable (replace - with _)
    safe_name = container_name.replace('-', '_').replace('.', '_')
    var = d.getVar('CONTAINER_%s_%s' % (safe_name, var_name))
    if var:
        return var
    # Also try with original name (in case user used original format)
    var = d.getVar('CONTAINER_%s_%s' % (container_name, var_name))
    return var if var else default

def get_container_list(d):
    """Get the list of container names from CONTAINERS variable."""
    containers = d.getVar('CONTAINERS') or ''
    return [c.strip() for c in containers.split() if c.strip()]

def get_pod_list(d):
    """Get the list of pod names from PODS variable."""
    pods = d.getVar('PODS') or ''
    return [p.strip() for p in pods.split() if p.strip()]

def get_pod_var(d, pod_name, var_name, default=''):
    """Get a pod-specific variable with fallback to default."""
    # Sanitize pod name for BitBake variable (replace - with _)
    safe_name = pod_name.replace('-', '_').replace('.', '_')
    var = d.getVar('POD_%s_%s' % (safe_name, var_name))
    if var:
        return var
    # Also try with original name (in case user used original format)
    var = d.getVar('POD_%s_%s' % (pod_name, var_name))
    return var if var else default

# All container configuration variable suffixes
CONTAINER_VAR_SUFFIXES = "IMAGE PORTS VOLUMES ENVIRONMENT NETWORK RESTART USER WORKING_DIR DEVICES CAPS_ADD CAPS_DROP PRIVILEGED READ_ONLY MEMORY_LIMIT CPU_LIMIT ENABLED LABELS DEPENDS_ON ENTRYPOINT COMMAND PULL_POLICY DIGEST AUTH_FILE SECURITY_OPTS POD"

# All pod configuration variable suffixes
POD_VAR_SUFFIXES = "PORTS NETWORK VOLUMES LABELS DNS DNS_SEARCH HOSTNAME IP MAC ADD_HOST USERNS ENABLED"

# Validate container and pod configuration at parse time and set up vardeps
python __anonymous() {
    containers = get_container_list(d)
    pods = get_pod_list(d)

    if not containers and not pods:
        return

    # Build list of all container variables for vardeps
    var_suffixes = (d.getVar('CONTAINER_VAR_SUFFIXES') or '').split()
    all_vars = ['CONTAINERS', 'PODS']

    for container_name in containers:
        safe_name = container_name.replace('-', '_').replace('.', '_')
        for suffix in var_suffixes:
            all_vars.append(f'CONTAINER_{safe_name}_{suffix}')

        image = get_container_var(d, container_name, 'IMAGE')
        if not image:
            bb.fatal("CONTAINER_%s_IMAGE must be set for container '%s'" %
                     (container_name.replace('-', '_'), container_name))

        # Validate restart policy if specified
        restart = get_container_var(d, container_name, 'RESTART', 'always')
        valid_restart = ['always', 'on-failure', 'no', '']
        if restart not in valid_restart:
            bb.fatal("CONTAINER_%s_RESTART must be one of: %s" %
                     (container_name.replace('-', '_'), ', '.join(valid_restart)))

        # Security warnings
        if get_container_var(d, container_name, 'PRIVILEGED') == '1':
            bb.warn("Container '%s' is configured for privileged mode - use with caution" % container_name)

        if get_container_var(d, container_name, 'NETWORK') == 'host':
            bb.warn("Container '%s' uses host networking - network isolation disabled" % container_name)

        # Warn if pod member defines ports
        pod = get_container_var(d, container_name, 'POD')
        ports = get_container_var(d, container_name, 'PORTS')
        if pod and ports:
            bb.warn("Container '%s' is a pod member but defines CONTAINER_%s_PORTS. "
                    "Ports should be defined on the pod, not individual containers." %
                    (container_name, container_name.replace('-', '_')))

        # Validate pod reference exists
        if pod and pods and pod not in pods:
            bb.warn("Container '%s' references pod '%s' which is not in PODS list" %
                    (container_name, pod))

    # Build list of all pod variables for vardeps
    pod_var_suffixes = (d.getVar('POD_VAR_SUFFIXES') or '').split()

    for pod_name in pods:
        safe_name = pod_name.replace('-', '_').replace('.', '_')
        for suffix in pod_var_suffixes:
            all_vars.append(f'POD_{safe_name}_{suffix}')

        # Security warnings for pods
        if get_pod_var(d, pod_name, 'NETWORK') == 'host':
            bb.warn("Pod '%s' uses host networking - network isolation disabled" % pod_name)

    # Set vardeps for tasks that depend on container/pod configuration
    vardeps_str = ' '.join(all_vars)
    d.appendVarFlag('do_generate_quadlets', 'vardeps', ' ' + vardeps_str)
    d.appendVarFlag('do_generate_pods', 'vardeps', ' ' + vardeps_str)
    d.appendVarFlag('do_generate_import_scripts', 'vardeps', ' ' + vardeps_str)
    d.appendVarFlag('do_pull_containers', 'vardeps', ' ' + vardeps_str)

    if containers:
        bb.note("Configured %d containers from local.conf: %s" % (len(containers), ', '.join(containers)))
    if pods:
        bb.note("Configured %d pods from local.conf: %s" % (len(pods), ', '.join(pods)))
}

# Pull all container images using skopeo-native
python do_pull_containers() {
    import subprocess
    import os

    containers = get_container_list(d)
    if not containers:
        bb.note("No containers configured in CONTAINERS variable")
        return

    workdir = d.getVar('WORKDIR')
    oci_arch = get_oci_arch(d)

    for container_name in containers:
        image = get_container_var(d, container_name, 'IMAGE')
        digest = get_container_var(d, container_name, 'DIGEST')
        auth_file = get_container_var(d, container_name, 'AUTH_FILE')

        # Determine full image reference
        if digest:
            image_base = image.split(':')[0]
            full_image = f"{image_base}@{digest}"
        else:
            full_image = image

        bb.note(f"Pulling container image '{container_name}': {full_image}")
        bb.note(f"Target OCI architecture: {oci_arch}")

        # Create storage directory
        oci_dir = os.path.join(workdir, 'container-oci', container_name)
        os.makedirs(oci_dir, exist_ok=True)

        # Build skopeo command
        skopeo_args = ['skopeo', 'copy', '--override-arch', oci_arch]

        if auth_file and os.path.exists(auth_file):
            skopeo_args.extend(['--authfile', auth_file])
            bb.note(f"Using auth file: {auth_file}")

        # Add source and destination
        skopeo_args.append(f"docker://{full_image}")
        skopeo_args.append(f"oci:{oci_dir}:latest")

        bb.note(f"Running: {' '.join(skopeo_args)}")

        # Run skopeo
        try:
            result = subprocess.run(skopeo_args, check=True, capture_output=True, text=True)
            bb.note(f"Container image '{container_name}' pulled successfully")
            if result.stdout:
                bb.note(result.stdout)
        except subprocess.CalledProcessError as e:
            bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): {e.stderr}")
}

addtask do_pull_containers after do_configure before do_compile
do_pull_containers[network] = "1"
do_pull_containers[vardeps] = "CONTAINERS"

# Generate Quadlet files for all containers
python do_generate_quadlets() {
    import os

    containers = get_container_list(d)
    if not containers:
        return

    workdir = d.getVar('WORKDIR')

    for container_name in containers:
        image = get_container_var(d, container_name, 'IMAGE')

        # Build Quadlet file content
        lines = []

        # [Unit] section
        lines.append("# Podman Quadlet file for " + container_name)
        lines.append("# Auto-generated by meta-container-deploy (container-localconf)")
        lines.append("")
        lines.append("[Unit]")
        lines.append("Description=" + container_name + " container service")
        lines.append("After=network-online.target container-import.service")

        # Add dependencies on other containers
        depends_on = get_container_var(d, container_name, 'DEPENDS_ON')
        if depends_on:
            for dep in depends_on.split():
                lines.append("After=" + dep + ".service")
                lines.append("Requires=" + dep + ".service")

        lines.append("Wants=network-online.target")
        lines.append("")

        # [Container] section
        lines.append("[Container]")
        lines.append("Image=" + image)

        # Pod membership
        pod = get_container_var(d, container_name, 'POD')
        if pod:
            lines.append("Pod=" + pod + ".pod")

        # Entrypoint and command
        entrypoint = get_container_var(d, container_name, 'ENTRYPOINT')
        if entrypoint:
            lines.append("Exec=" + entrypoint)

        command = get_container_var(d, container_name, 'COMMAND')
        if command:
            lines.append("Exec=" + command)

        # Environment variables
        environment = get_container_var(d, container_name, 'ENVIRONMENT')
        if environment:
            for env in environment.split():
                if '=' in env:
                    lines.append("Environment=" + env)

        # Port mappings
        ports = get_container_var(d, container_name, 'PORTS')
        if ports:
            for port in ports.split():
                lines.append("PublishPort=" + port)

        # Volume mounts
        volumes = get_container_var(d, container_name, 'VOLUMES')
        if volumes:
            for volume in volumes.split():
                lines.append("Volume=" + volume)

        # Device passthrough
        devices = get_container_var(d, container_name, 'DEVICES')
        if devices:
            for device in devices.split():
                lines.append("AddDevice=" + device)

        # Network mode
        network = get_container_var(d, container_name, 'NETWORK')
        if network:
            lines.append("Network=" + network)

        # User
        user = get_container_var(d, container_name, 'USER')
        if user:
            lines.append("User=" + user)

        # Working directory
        working_dir = get_container_var(d, container_name, 'WORKING_DIR')
        if working_dir:
            lines.append("WorkingDir=" + working_dir)

        # Labels
        labels = get_container_var(d, container_name, 'LABELS')
        if labels:
            for label in labels.split():
                if '=' in label:
                    lines.append("Label=" + label)

        # Security options
        privileged = get_container_var(d, container_name, 'PRIVILEGED')
        if privileged == '1':
            lines.append("SecurityLabelDisable=true")

        security_opts = get_container_var(d, container_name, 'SECURITY_OPTS')
        if security_opts:
            for opt in security_opts.split():
                lines.append("SecurityOpt=" + opt)

        # Capabilities
        caps_add = get_container_var(d, container_name, 'CAPS_ADD')
        if caps_add:
            for cap in caps_add.split():
                lines.append("AddCapability=" + cap)

        caps_drop = get_container_var(d, container_name, 'CAPS_DROP')
        if caps_drop:
            for cap in caps_drop.split():
                lines.append("DropCapability=" + cap)

        # Read-only root filesystem
        read_only = get_container_var(d, container_name, 'READ_ONLY')
        if read_only == '1':
            lines.append("ReadOnly=true")

        # Resource limits (via PodmanArgs)
        memory_limit = get_container_var(d, container_name, 'MEMORY_LIMIT')
        if memory_limit:
            lines.append("PodmanArgs=--memory " + memory_limit)

        cpu_limit = get_container_var(d, container_name, 'CPU_LIMIT')
        if cpu_limit:
            lines.append("PodmanArgs=--cpus " + cpu_limit)

        lines.append("")

        # [Service] section
        lines.append("[Service]")
        restart = get_container_var(d, container_name, 'RESTART', 'always')
        lines.append("Restart=" + restart)
        lines.append("TimeoutStartSec=900")
        lines.append("")

        # [Install] section
        lines.append("[Install]")
        enabled = get_container_var(d, container_name, 'ENABLED', '1')
        if enabled != '0':
            lines.append("WantedBy=multi-user.target")
        else:
            lines.append("# Container disabled - uncomment to enable")
            lines.append("# WantedBy=multi-user.target")

        # Write the Quadlet file
        quadlet_dir = os.path.join(workdir, 'quadlets')
        os.makedirs(quadlet_dir, exist_ok=True)
        quadlet_file = os.path.join(quadlet_dir, container_name + ".container")

        with open(quadlet_file, 'w') as f:
            f.write('\n'.join(lines))
            f.write('\n')

        bb.note("Generated Quadlet file for '%s': %s" % (container_name, quadlet_file))
}

addtask do_generate_quadlets after do_configure before do_compile

# Generate Quadlet .pod files for all pods
python do_generate_pods() {
    import os

    pods = get_pod_list(d)
    if not pods:
        return

    workdir = d.getVar('WORKDIR')

    for pod_name in pods:
        # Build Quadlet pod file content
        lines = []

        # [Unit] section
        lines.append("# Podman Quadlet pod file for " + pod_name)
        lines.append("# Auto-generated by meta-container-deploy (container-localconf)")
        lines.append("")
        lines.append("[Unit]")
        lines.append("Description=" + pod_name + " pod")
        lines.append("After=network-online.target container-import.service")
        lines.append("Wants=network-online.target")
        lines.append("")

        # [Pod] section
        lines.append("[Pod]")
        lines.append("PodName=" + pod_name)

        # Port mappings (pods handle ports, not individual containers)
        ports = get_pod_var(d, pod_name, 'PORTS')
        if ports:
            for port in ports.split():
                lines.append("PublishPort=" + port)

        # Network mode
        network = get_pod_var(d, pod_name, 'NETWORK')
        if network:
            lines.append("Network=" + network)

        # Volume mounts (shared by all containers in pod)
        volumes = get_pod_var(d, pod_name, 'VOLUMES')
        if volumes:
            for volume in volumes.split():
                lines.append("Volume=" + volume)

        # Labels
        labels = get_pod_var(d, pod_name, 'LABELS')
        if labels:
            for label in labels.split():
                if '=' in label:
                    lines.append("Label=" + label)

        # DNS configuration
        dns = get_pod_var(d, pod_name, 'DNS')
        if dns:
            for server in dns.split():
                lines.append("DNS=" + server)

        dns_search = get_pod_var(d, pod_name, 'DNS_SEARCH')
        if dns_search:
            for domain in dns_search.split():
                lines.append("DNSSearch=" + domain)

        # Hostname
        hostname = get_pod_var(d, pod_name, 'HOSTNAME')
        if hostname:
            lines.append("Hostname=" + hostname)

        # Static IP/MAC
        ip = get_pod_var(d, pod_name, 'IP')
        if ip:
            lines.append("IP=" + ip)

        mac = get_pod_var(d, pod_name, 'MAC')
        if mac:
            lines.append("MAC=" + mac)

        # Host mappings for /etc/hosts
        add_host = get_pod_var(d, pod_name, 'ADD_HOST')
        if add_host:
            for mapping in add_host.split():
                lines.append("AddHost=" + mapping)

        # User namespace
        userns = get_pod_var(d, pod_name, 'USERNS')
        if userns:
            lines.append("Userns=" + userns)

        lines.append("")

        # [Install] section
        lines.append("[Install]")
        enabled = get_pod_var(d, pod_name, 'ENABLED', '1')
        if enabled != '0':
            lines.append("WantedBy=multi-user.target")
        else:
            lines.append("# Pod disabled - uncomment to enable")
            lines.append("# WantedBy=multi-user.target")

        # Write the Quadlet pod file
        quadlet_dir = os.path.join(workdir, 'quadlets')
        os.makedirs(quadlet_dir, exist_ok=True)
        pod_file = os.path.join(quadlet_dir, pod_name + ".pod")

        with open(pod_file, 'w') as f:
            f.write('\n'.join(lines))
            f.write('\n')

        bb.note("Generated Quadlet pod file for '%s': %s" % (pod_name, pod_file))
}

addtask do_generate_pods after do_configure before do_compile

# Generate import scripts for all containers
python do_generate_import_scripts() {
    import os

    containers = get_container_list(d)
    if not containers:
        return

    workdir = d.getVar('WORKDIR')
    preload_dir = d.getVar('CONTAINER_PRELOAD_DIR')
    marker_dir = d.getVar('CONTAINER_IMPORT_MARKER_DIR')

    scripts_dir = os.path.join(workdir, 'import-scripts')
    os.makedirs(scripts_dir, exist_ok=True)

    for container_name in containers:
        image = get_container_var(d, container_name, 'IMAGE')

        script_content = f'''#!/bin/sh
# Import container image: {container_name}
# Source image: {image}

CONTAINER_NAME="{container_name}"
CONTAINER_IMAGE="{image}"
IMAGE_DIR="{preload_dir}/{container_name}"
MARKER_FILE="{marker_dir}/{container_name}"

if [ -d "$IMAGE_DIR" ] && [ ! -f "$MARKER_FILE" ]; then
    echo "Importing container image: $CONTAINER_IMAGE"

    # Import using skopeo (preferred) or podman load
    if command -v skopeo >/dev/null 2>&1; then
        skopeo copy oci:"$IMAGE_DIR":latest containers-storage:"$CONTAINER_IMAGE"
    else
        # Fallback to podman if skopeo not available at runtime
        podman load -i "$IMAGE_DIR"
    fi

    if [ $? -eq 0 ]; then
        touch "$MARKER_FILE"
        echo "Container image $CONTAINER_NAME imported successfully"
    else
        echo "Failed to import container image $CONTAINER_NAME" >&2
        exit 1
    fi
else
    if [ -f "$MARKER_FILE" ]; then
        echo "Container image $CONTAINER_NAME already imported"
    else
        echo "Container image directory not found: $IMAGE_DIR" >&2
        exit 1
    fi
fi
'''

        script_file = os.path.join(scripts_dir, container_name + '.sh')
        with open(script_file, 'w') as f:
            f.write(script_content)

        bb.note("Generated import script for '%s': %s" % (container_name, script_file))
}

addtask do_generate_import_scripts after do_configure before do_compile

# Install all container artifacts
do_install:append() {
    # Get list of containers
    for CONTAINER_NAME in ${CONTAINERS}; do
        if [ -d "${WORKDIR}/container-oci/${CONTAINER_NAME}" ]; then
            # Install OCI image directory
            install -d ${D}${CONTAINER_PRELOAD_DIR}
            cp -r ${WORKDIR}/container-oci/${CONTAINER_NAME} \
                ${D}${CONTAINER_PRELOAD_DIR}/

            bbnote "Installed OCI image for container: ${CONTAINER_NAME}"
        else
            bbwarn "OCI image not found for container: ${CONTAINER_NAME}"
        fi

        # Install Quadlet file
        if [ -f "${WORKDIR}/quadlets/${CONTAINER_NAME}.container" ]; then
            install -d ${D}${QUADLET_DIR}
            install -m 0644 ${WORKDIR}/quadlets/${CONTAINER_NAME}.container \
                ${D}${QUADLET_DIR}/

            bbnote "Installed Quadlet file for container: ${CONTAINER_NAME}"
        fi

        # Install import script
        if [ -f "${WORKDIR}/import-scripts/${CONTAINER_NAME}.sh" ]; then
            install -d ${D}${sysconfdir}/containers/import.d
            install -m 0755 ${WORKDIR}/import-scripts/${CONTAINER_NAME}.sh \
                ${D}${sysconfdir}/containers/import.d/

            bbnote "Installed import script for container: ${CONTAINER_NAME}"
        fi
    done

    # Install pod Quadlet files
    for POD_NAME in ${PODS}; do
        if [ -f "${WORKDIR}/quadlets/${POD_NAME}.pod" ]; then
            install -d ${D}${QUADLET_DIR}
            install -m 0644 ${WORKDIR}/quadlets/${POD_NAME}.pod \
                ${D}${QUADLET_DIR}/

            bbnote "Installed Quadlet pod file for: ${POD_NAME}"
        fi
    done

    # Create import marker directory
    install -d ${D}${CONTAINER_IMPORT_MARKER_DIR}
}

# Set FILES to include all container and pod artifacts
# Using wildcards since containers/pods are determined at parse time
FILES:${PN} += "\
    ${CONTAINER_PRELOAD_DIR}/* \
    ${QUADLET_DIR}/*.container \
    ${QUADLET_DIR}/*.pod \
    ${sysconfdir}/containers/import.d/*.sh \
    ${CONTAINER_IMPORT_MARKER_DIR} \
"

# Disable automatic packaging of -dev, -dbg, -src, etc. since we only produce data files
PACKAGES = "${PN}"
