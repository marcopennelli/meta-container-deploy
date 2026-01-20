# SPDX-License-Identifier: MIT
#
# container-manifest.bbclass - Parse YAML/JSON container manifests
#
# This class parses a container manifest file (YAML or JSON) and pulls
# container images at build time, generating Quadlet files for systemd
# service management. Designed for declarative container deployment in
# standalone Yocto/OpenEmbedded projects.
#
# Usage:
#   In local.conf or image recipe:
#     CONTAINER_MANIFEST = "${TOPDIR}/../containers.yaml"
#
#   Then add to your image:
#     IMAGE_INSTALL:append = " packagegroup-containers-manifest"
#
# Manifest format (YAML):
#   containers:
#     - name: mqtt-broker
#       image: docker.io/eclipse-mosquitto:2.0
#       ports:
#         - "1883:1883"
#       volumes:
#         - "/data/mosquitto:/mosquitto/data:rw"
#       restart_policy: always
#       environment:
#         MQTT_USER: admin
#       network: bridge
#
#     - name: node-red
#       image: docker.io/nodered/node-red:latest
#       ports:
#         - "1880:1880"
#       depends_on:
#         - mqtt-broker
#
# Manifest format (JSON):
#   {
#     "containers": [
#       {
#         "name": "mqtt-broker",
#         "image": "docker.io/eclipse-mosquitto:2.0",
#         "ports": ["1883:1883"],
#         "restart_policy": "always"
#       }
#     ]
#   }
#
# Container configuration options:
#   name (required)       - Container name (used for service/file naming)
#   image (required)      - Container image reference
#   ports                 - List of port mappings ("host:container")
#   volumes               - List of volume mounts ("host:container:mode")
#   environment           - Dict or list of environment variables
#   network               - Network mode: host, bridge, none, or custom name
#   restart_policy        - Restart policy: always, on-failure, no (default: always)
#   user                  - User to run container as
#   working_dir           - Working directory in container
#   devices               - List of device paths to pass through
#   capabilities_add      - List of capabilities to add
#   capabilities_drop     - List of capabilities to drop
#   privileged            - Boolean for privileged mode
#   read_only             - Boolean for read-only root filesystem
#   memory_limit          - Memory limit (e.g., "512m", "1g")
#   cpu_limit             - CPU limit (e.g., "0.5", "2")
#   enabled               - Boolean to enable/disable auto-start (default: true)
#   labels                - Dict or list of container labels
#   depends_on            - List of container names this depends on
#   entrypoint            - Override container entrypoint
#   command               - Command arguments
#   pull_policy           - Pull policy: always, missing, never (default: missing)
#   digest                - Pin to specific image digest for reproducibility
#   registry.auth_secret  - Path to registry auth file
#   pod                   - Pod name to join (makes container a pod member)
#   verify                - Pre-pull verification: true to enable (default: false)
#
# Global verification option (in local.conf):
#   CONTAINERS_VERIFY - Enable pre-pull verification for all containers ("1" to enable)
#
# Pod manifest format:
#   pods:
#     - name: myapp
#       ports:
#         - "8080:8080"
#         - "8081:8081"
#       network: bridge
#       volumes:
#         - "/data:/app/data:rw"
#       hostname: myapp-pod
#       enabled: true
#
# Pod configuration options:
#   name (required)       - Pod name (used for service/file naming)
#   ports                 - List of port mappings (centralized for all containers)
#   network               - Network mode: host, bridge, none, or custom name
#   volumes               - List of volume mounts shared by all containers
#   labels                - Dict or list of pod labels
#   dns                   - List of DNS server addresses
#   dns_search            - List of DNS search domains
#   hostname              - Hostname for the pod
#   ip                    - Static IP address for the pod
#   mac                   - Static MAC address for the pod
#   add_host              - List of host:ip mappings for /etc/hosts
#   userns                - User namespace mode
#   enabled               - Boolean to enable/disable auto-start (default: true)
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>
# SPDX-License-Identifier: MIT

DEPENDS += "skopeo-native python3-pyyaml-native"
RDEPENDS:${PN} += "podman container-import"

# Manifest file location
CONTAINER_MANIFEST ?= ""

# Global pre-pull verification flag
CONTAINERS_VERIFY ?= "0"

# OCI storage locations
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

def get_container_from_manifest(containers, name):
    """Get a container dict from parsed manifest by name."""
    for c in containers:
        if c.get('name') == name:
            return c
    return {}

def get_container_list_from_manifest(d):
    """Get list of container names from parsed manifest."""
    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return []
    containers, _ = parse_container_manifest(manifest_path, d)
    return [c.get('name', '') for c in containers if c.get('name')]

def get_pod_list_from_manifest(d):
    """Get list of pod names from parsed manifest."""
    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return []
    _, pods = parse_container_manifest(manifest_path, d)
    return [p.get('name', '') for p in pods if p.get('name')]

# Python function to parse manifest and validate at parse time
python __anonymous() {
    import os

    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return

    if not os.path.exists(manifest_path):
        bb.warn("Container manifest not found: %s" % manifest_path)
        return

    # Parse the manifest
    try:
        containers, pods = parse_container_manifest(manifest_path, d)

        # Get pod names for validation
        pod_names = [p.get('name', '') for p in pods if p.get('name')]

        if containers:
            # Store parsed containers for later use
            d.setVar('CONTAINER_MANIFEST_PARSED', str(containers))

            # Store container names in CONTAINERS variable for shell tasks
            container_names = [c.get('name', '') for c in containers if c.get('name')]
            d.setVar('CONTAINERS_FROM_MANIFEST', ' '.join(container_names))

            # Validate each container
            for container in containers:
                name = container.get('name', '')
                if not name:
                    bb.fatal("Container in manifest is missing 'name' field")

                image = container.get('image', '')
                if not image:
                    bb.fatal("Container '%s' in manifest is missing 'image' field" % name)

                # Validate restart policy if specified
                restart = container.get('restart_policy', 'always')
                valid_restart = ['always', 'on-failure', 'no', '']
                if restart not in valid_restart:
                    bb.fatal("Container '%s' has invalid restart_policy '%s'. Must be one of: %s" %
                             (name, restart, ', '.join(valid_restart)))

                # Security warnings
                if container.get('privileged'):
                    bb.warn("Container '%s' is configured for privileged mode - use with caution" % name)

                if container.get('network') == 'host':
                    bb.warn("Container '%s' uses host networking - network isolation disabled" % name)

                # Warn if pod member defines ports
                pod = container.get('pod', '')
                ports = container.get('ports', [])
                if pod and ports:
                    bb.warn("Container '%s' is a pod member but defines 'ports'. "
                            "Ports should be defined on the pod, not individual containers." % name)

                # Validate pod reference exists
                if pod and pod_names and pod not in pod_names:
                    bb.warn("Container '%s' references pod '%s' which is not defined in manifest" %
                            (name, pod))

            bb.note("Parsed and validated %d containers from manifest: %s" %
                    (len(containers), ', '.join(container_names)))

        if pods:
            # Store parsed pods for later use
            d.setVar('POD_MANIFEST_PARSED', str(pods))

            # Store pod names for shell tasks
            d.setVar('PODS_FROM_MANIFEST', ' '.join(pod_names))

            # Validate each pod
            for pod in pods:
                name = pod.get('name', '')
                if not name:
                    bb.fatal("Pod in manifest is missing 'name' field")

                # Security warnings
                if pod.get('network') == 'host':
                    bb.warn("Pod '%s' uses host networking - network isolation disabled" % name)

            bb.note("Parsed and validated %d pods from manifest: %s" %
                    (len(pods), ', '.join(pod_names)))

    except Exception as e:
        bb.fatal("Failed to parse container manifest: %s" % str(e))
}

def parse_container_manifest(manifest_path, d):
    """Parse a YAML or JSON container manifest file. Returns (containers, pods) tuple."""
    import json

    with open(manifest_path, 'r') as f:
        content = f.read()

    # Try JSON first (it's a subset of YAML)
    try:
        data = json.loads(content)
    except json.JSONDecodeError:
        # Try YAML
        try:
            import yaml
            data = yaml.safe_load(content)
        except ImportError:
            bb.fatal("python3-pyyaml is required for YAML manifest parsing")
        except yaml.YAMLError as e:
            bb.fatal("Invalid YAML in manifest: %s" % str(e))

    if not isinstance(data, dict):
        bb.fatal("Container manifest must be a dictionary with 'containers' and/or 'pods' key")

    containers = data.get('containers', [])
    if not isinstance(containers, list):
        bb.fatal("'containers' must be a list in the manifest")

    pods = data.get('pods', [])
    if not isinstance(pods, list):
        bb.fatal("'pods' must be a list in the manifest")

    return containers, pods

def parse_container_manifest_containers_only(manifest_path, d):
    """Legacy wrapper that returns only containers for backward compatibility."""
    containers, _ = parse_container_manifest(manifest_path, d)
    return containers

def container_to_bitbake_vars(container, d):
    """Convert a container dict to BitBake variable assignments."""
    var_map = {
        'name': 'CONTAINER_NAME',
        'image': 'CONTAINER_IMAGE',
        'entrypoint': 'CONTAINER_ENTRYPOINT',
        'command': 'CONTAINER_COMMAND',
        'network': 'CONTAINER_NETWORK',
        'restart_policy': 'CONTAINER_RESTART',
        'user': 'CONTAINER_USER',
        'working_dir': 'CONTAINER_WORKING_DIR',
        'memory_limit': 'CONTAINER_MEMORY_LIMIT',
        'cpu_limit': 'CONTAINER_CPU_LIMIT',
        'pull_policy': 'CONTAINER_PULL_POLICY',
    }

    # Handle simple string mappings
    for manifest_key, bb_var in var_map.items():
        value = container.get(manifest_key)
        if value:
            if isinstance(value, list):
                d.setVar(bb_var, ' '.join(str(v) for v in value))
            else:
                d.setVar(bb_var, str(value))

    # Handle boolean flags
    if container.get('privileged'):
        d.setVar('CONTAINER_PRIVILEGED', '1')
    if container.get('read_only'):
        d.setVar('CONTAINER_READ_ONLY', '1')

    # Handle enabled flag (default True)
    enabled = container.get('enabled', True)
    d.setVar('CONTAINER_ENABLED', '1' if enabled else '0')

    # Handle list fields
    list_fields = {
        'ports': 'CONTAINER_PORTS',
        'volumes': 'CONTAINER_VOLUMES',
        'devices': 'CONTAINER_DEVICES',
        'depends_on': 'CONTAINER_DEPENDS_ON',
        'capabilities_add': 'CONTAINER_CAPS_ADD',
        'capabilities_drop': 'CONTAINER_CAPS_DROP',
        'security_opts': 'CONTAINER_SECURITY_OPTS',
    }

    for manifest_key, bb_var in list_fields.items():
        value = container.get(manifest_key, [])
        if value:
            if isinstance(value, list):
                d.setVar(bb_var, ' '.join(str(v) for v in value))
            else:
                d.setVar(bb_var, str(value))

    # Handle environment variables (dict to KEY=value format)
    env = container.get('environment', {})
    if env:
        if isinstance(env, dict):
            env_list = ['%s=%s' % (k, v) for k, v in env.items()]
            d.setVar('CONTAINER_ENVIRONMENT', ' '.join(env_list))
        elif isinstance(env, list):
            d.setVar('CONTAINER_ENVIRONMENT', ' '.join(env))

    # Handle labels (dict to key=value format)
    labels = container.get('labels', {})
    if labels:
        if isinstance(labels, dict):
            label_list = ['%s=%s' % (k, v) for k, v in labels.items()]
            d.setVar('CONTAINER_LABELS', ' '.join(label_list))
        elif isinstance(labels, list):
            d.setVar('CONTAINER_LABELS', ' '.join(labels))

    # Handle registry configuration
    registry = container.get('registry', {})
    if registry:
        auth_secret = registry.get('auth_secret', '')
        if auth_secret:
            d.setVar('CONTAINER_AUTH_FILE', auth_secret)

# Utility function to get list of container names from manifest
def get_container_names_from_manifest(manifest_path):
    """Extract container names from a manifest file."""
    import json

    if not manifest_path or not os.path.exists(manifest_path):
        return []

    with open(manifest_path, 'r') as f:
        content = f.read()

    try:
        data = json.loads(content)
    except json.JSONDecodeError:
        try:
            import yaml
            data = yaml.safe_load(content)
        except:
            return []

    containers = data.get('containers', [])
    return [c.get('name', '') for c in containers if c.get('name')]

def verify_oci_image(oci_dir, container_name, full_image, d):
    """Verify the pulled OCI image has valid structure."""
    import os
    import json

    bb.note(f"Verifying OCI image structure for '{container_name}'")

    # Check required OCI layout file
    oci_layout = os.path.join(oci_dir, 'oci-layout')
    if not os.path.exists(oci_layout):
        bb.fatal(f"OCI image verification failed for '{container_name}': missing oci-layout file")

    try:
        with open(oci_layout, 'r') as f:
            layout = json.load(f)
        if layout.get('imageLayoutVersion') != '1.0.0':
            bb.warn(f"Unexpected OCI layout version for '{container_name}': {layout.get('imageLayoutVersion')}")
    except (json.JSONDecodeError, IOError) as e:
        bb.fatal(f"OCI image verification failed for '{container_name}': invalid oci-layout file: {e}")

    # Check index.json exists
    index_file = os.path.join(oci_dir, 'index.json')
    if not os.path.exists(index_file):
        bb.fatal(f"OCI image verification failed for '{container_name}': missing index.json")

    try:
        with open(index_file, 'r') as f:
            index = json.load(f)
        manifests = index.get('manifests', [])
        if not manifests:
            bb.fatal(f"OCI image verification failed for '{container_name}': no manifests in index.json")
    except (json.JSONDecodeError, IOError) as e:
        bb.fatal(f"OCI image verification failed for '{container_name}': invalid index.json: {e}")

    # Check blobs directory exists and has content
    blobs_dir = os.path.join(oci_dir, 'blobs')
    if not os.path.isdir(blobs_dir):
        bb.fatal(f"OCI image verification failed for '{container_name}': missing blobs directory")

    # Verify at least one blob exists
    blob_count = 0
    for root, dirs, files in os.walk(blobs_dir):
        blob_count += len(files)

    if blob_count == 0:
        bb.fatal(f"OCI image verification failed for '{container_name}': no blobs found")

    bb.note(f"OCI image verified for '{container_name}': {blob_count} blobs, {len(manifests)} manifest(s)")

# Optional pre-pull verification using skopeo inspect
# Enable with CONTAINERS_VERIFY = "1" or per-container verify: true in manifest
python do_verify_containers() {
    import subprocess
    import os

    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return

    containers, _ = parse_container_manifest(manifest_path, d)
    if not containers:
        return

    global_verify = d.getVar('CONTAINERS_VERIFY') == '1'
    oci_arch = get_oci_arch(d)

    for container in containers:
        container_name = container.get('name', '')
        # Check per-container or global verify flag
        container_verify = container.get('verify', False)
        if not container_verify and not global_verify:
            continue

        image = container.get('image', '')
        digest = container.get('digest', '')
        registry = container.get('registry', {})
        auth_file = registry.get('auth_secret', '') if registry else ''

        # Determine full image reference
        if digest:
            image_base = image.split(':')[0]
            full_image = f"{image_base}@{digest}"
        else:
            full_image = image

        bb.note(f"Verifying container image exists: '{container_name}' ({full_image})")

        # Build skopeo inspect command
        skopeo_args = ['skopeo', 'inspect', '--override-arch', oci_arch]

        if auth_file and os.path.exists(auth_file):
            skopeo_args.extend(['--authfile', auth_file])

        skopeo_args.append(f"docker://{full_image}")

        try:
            subprocess.run(skopeo_args, check=True)
            bb.note(f"Container image '{container_name}' verified: {full_image}")
        except subprocess.CalledProcessError as e:
            bb.fatal(f"Container image verification failed for '{container_name}' ({full_image}). "
                     f"Image may not exist, wrong architecture, or authentication required.")
}
addtask do_verify_containers after do_configure before do_pull_containers
do_verify_containers[network] = "1"
do_verify_containers[vardeps] = "CONTAINER_MANIFEST CONTAINERS_VERIFY"

# Pull all container images using skopeo-native
python do_pull_containers() {
    import subprocess
    import os

    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        bb.note("No container manifest configured")
        return

    containers, _ = parse_container_manifest(manifest_path, d)
    if not containers:
        bb.note("No containers found in manifest")
        return

    workdir = d.getVar('WORKDIR')
    oci_arch = get_oci_arch(d)

    for container in containers:
        container_name = container.get('name', '')
        image = container.get('image', '')
        digest = container.get('digest', '')
        registry = container.get('registry', {})
        auth_file = registry.get('auth_secret', '') if registry else ''

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
            subprocess.run(skopeo_args, check=True)
            bb.note(f"Container image '{container_name}' pulled successfully")
        except subprocess.CalledProcessError as e:
            bb.fatal(f"Failed to pull container image '{container_name}' ({full_image})")

        # Post-pull verification (default behavior)
        verify_oci_image(oci_dir, container_name, full_image, d)
}

addtask do_pull_containers after do_verify_containers before do_compile
do_pull_containers[network] = "1"
do_pull_containers[vardeps] = "CONTAINER_MANIFEST"

# Generate Quadlet files for all containers
python do_generate_quadlets() {
    import os

    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return

    containers, _ = parse_container_manifest(manifest_path, d)
    if not containers:
        return

    workdir = d.getVar('WORKDIR')

    for container in containers:
        container_name = container.get('name', '')
        image = container.get('image', '')

        # Build Quadlet file content
        lines = []

        # [Unit] section
        lines.append("# Podman Quadlet file for " + container_name)
        lines.append("# Auto-generated by meta-container-deploy (container-manifest)")
        lines.append("")
        lines.append("[Unit]")
        lines.append("Description=" + container_name + " container service")
        lines.append("After=network-online.target container-import.service")

        # Add dependencies on other containers
        depends_on = container.get('depends_on', [])
        if depends_on:
            for dep in depends_on:
                lines.append("After=" + dep + ".service")
                lines.append("Requires=" + dep + ".service")

        lines.append("Wants=network-online.target")
        lines.append("")

        # [Container] section
        lines.append("[Container]")
        lines.append("Image=" + image)

        # Pod membership
        pod = container.get('pod', '')
        if pod:
            lines.append("Pod=" + pod + ".pod")

        # Entrypoint and command
        entrypoint = container.get('entrypoint', '')
        if entrypoint:
            lines.append("Exec=" + entrypoint)

        command = container.get('command', '')
        if command:
            lines.append("Exec=" + command)

        # Environment variables
        environment = container.get('environment', {})
        if environment:
            if isinstance(environment, dict):
                for key, value in environment.items():
                    lines.append(f"Environment={key}={value}")
            elif isinstance(environment, list):
                for env in environment:
                    lines.append("Environment=" + env)

        # Port mappings
        ports = container.get('ports', [])
        if ports:
            for port in ports:
                lines.append("PublishPort=" + str(port))

        # Volume mounts
        volumes = container.get('volumes', [])
        if volumes:
            for volume in volumes:
                lines.append("Volume=" + str(volume))

        # Device passthrough
        devices = container.get('devices', [])
        if devices:
            for device in devices:
                lines.append("AddDevice=" + str(device))

        # Network mode
        network = container.get('network', '')
        if network:
            lines.append("Network=" + network)

        # User
        user = container.get('user', '')
        if user:
            lines.append("User=" + user)

        # Working directory
        working_dir = container.get('working_dir', '')
        if working_dir:
            lines.append("WorkingDir=" + working_dir)

        # Labels
        labels = container.get('labels', {})
        if labels:
            if isinstance(labels, dict):
                for key, value in labels.items():
                    lines.append(f"Label={key}={value}")
            elif isinstance(labels, list):
                for label in labels:
                    lines.append("Label=" + label)

        # Security options
        if container.get('privileged'):
            lines.append("SecurityLabelDisable=true")

        security_opts = container.get('security_opts', [])
        if security_opts:
            for opt in security_opts:
                lines.append("SecurityOpt=" + opt)

        # Capabilities
        caps_add = container.get('capabilities_add', [])
        if caps_add:
            for cap in caps_add:
                lines.append("AddCapability=" + cap)

        caps_drop = container.get('capabilities_drop', [])
        if caps_drop:
            for cap in caps_drop:
                lines.append("DropCapability=" + cap)

        # Read-only root filesystem
        if container.get('read_only'):
            lines.append("ReadOnly=true")

        # Resource limits (via PodmanArgs)
        memory_limit = container.get('memory_limit', '')
        if memory_limit:
            lines.append("PodmanArgs=--memory " + memory_limit)

        cpu_limit = container.get('cpu_limit', '')
        if cpu_limit:
            lines.append("PodmanArgs=--cpus " + str(cpu_limit))

        lines.append("")

        # [Service] section
        lines.append("[Service]")
        restart = container.get('restart_policy', 'always')
        lines.append("Restart=" + restart)
        lines.append("TimeoutStartSec=900")
        lines.append("")

        # [Install] section
        lines.append("[Install]")
        enabled = container.get('enabled', True)
        if enabled:
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

    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return

    _, pods = parse_container_manifest(manifest_path, d)
    if not pods:
        return

    workdir = d.getVar('WORKDIR')

    for pod in pods:
        pod_name = pod.get('name', '')

        # Build Quadlet pod file content
        lines = []

        # [Unit] section
        lines.append("# Podman Quadlet pod file for " + pod_name)
        lines.append("# Auto-generated by meta-container-deploy (container-manifest)")
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
        ports = pod.get('ports', [])
        if ports:
            for port in ports:
                lines.append("PublishPort=" + str(port))

        # Network mode
        network = pod.get('network', '')
        if network:
            lines.append("Network=" + network)

        # Volume mounts (shared by all containers in pod)
        volumes = pod.get('volumes', [])
        if volumes:
            for volume in volumes:
                lines.append("Volume=" + str(volume))

        # Labels
        labels = pod.get('labels', {})
        if labels:
            if isinstance(labels, dict):
                for key, value in labels.items():
                    lines.append(f"Label={key}={value}")
            elif isinstance(labels, list):
                for label in labels:
                    lines.append("Label=" + label)

        # DNS configuration
        dns = pod.get('dns', [])
        if dns:
            for server in dns:
                lines.append("DNS=" + str(server))

        dns_search = pod.get('dns_search', [])
        if dns_search:
            for domain in dns_search:
                lines.append("DNSSearch=" + str(domain))

        # Hostname
        hostname = pod.get('hostname', '')
        if hostname:
            lines.append("Hostname=" + hostname)

        # Static IP/MAC
        ip = pod.get('ip', '')
        if ip:
            lines.append("IP=" + ip)

        mac = pod.get('mac', '')
        if mac:
            lines.append("MAC=" + mac)

        # Host mappings for /etc/hosts
        add_host = pod.get('add_host', [])
        if add_host:
            for mapping in add_host:
                lines.append("AddHost=" + str(mapping))

        # User namespace
        userns = pod.get('userns', '')
        if userns:
            lines.append("Userns=" + userns)

        lines.append("")

        # [Install] section
        lines.append("[Install]")
        enabled = pod.get('enabled', True)
        if enabled:
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

    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return

    containers, _ = parse_container_manifest(manifest_path, d)
    if not containers:
        return

    workdir = d.getVar('WORKDIR')
    preload_dir = d.getVar('CONTAINER_PRELOAD_DIR')
    marker_dir = d.getVar('CONTAINER_IMPORT_MARKER_DIR')

    scripts_dir = os.path.join(workdir, 'import-scripts')
    os.makedirs(scripts_dir, exist_ok=True)

    for container in containers:
        container_name = container.get('name', '')
        image = container.get('image', '')

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
    # Get list of containers from manifest
    MANIFEST_CONTAINERS="${CONTAINERS_FROM_MANIFEST}"

    for CONTAINER_NAME in $MANIFEST_CONTAINERS; do
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
    MANIFEST_PODS="${PODS_FROM_MANIFEST}"
    for POD_NAME in $MANIFEST_PODS; do
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
# Using wildcards since containers/pods are determined at parse time from manifest
FILES:${PN} += "\
    ${CONTAINER_PRELOAD_DIR}/* \
    ${QUADLET_DIR}/*.container \
    ${QUADLET_DIR}/*.pod \
    ${sysconfdir}/containers/import.d/*.sh \
    ${CONTAINER_IMPORT_MARKER_DIR} \
"

# Disable automatic packaging of -dev, -dbg, -src, etc. since we only produce data files
PACKAGES = "${PN}"
