# SPDX-License-Identifier: MIT
#
# container-manifest.bbclass - Parse YAML/JSON container manifests
#
# Inherit deploy class for DEPLOYDIR support
inherit deploy
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
#   enabled               - Boolean to enable/disable auto-start (default: true).
#                           Disabled containers are still pulled and imported into
#                           Podman storage, but their Quadlet files are installed to
#                           /etc/containers/systemd-available/ instead of the active
#                           /etc/containers/systemd/ directory. To enable at runtime:
#                             cp /etc/containers/systemd-available/<name>.container /etc/containers/systemd/
#                             systemctl daemon-reload && systemctl start <name>
#   labels                - Dict or list of container labels
#   depends_on            - List of container names this depends on
#   entrypoint            - Override container entrypoint
#   command               - Command arguments
#   pull_policy           - Pull policy: always, missing, never (default: missing)
#   digest                - Pin to specific image digest for reproducibility
#   registry.auth_secret  - Path to registry auth file (Docker/Podman config.json format)
#   registry.tls_verify   - TLS certificate verification: true (default) or false
#   registry.cert_dir     - Path to directory with custom CA certificates
#   pod                   - Pod name to join (makes container a pod member)
#   verify                - Pre-pull verification: true to enable (default: false)
#   cgroups               - Cgroups mode: enabled, disabled, no-conmon, split
#   sdnotify              - SD-Notify mode: conmon, container, healthy, ignore
#   timezone              - Container timezone (e.g., UTC, Europe/Rome, local)
#   stop_timeout          - Seconds to wait before force-killing (default: 10)
#   health_cmd            - Health check command
#   health_interval       - Interval between health checks (e.g., 30s)
#   health_timeout        - Timeout for health check (e.g., 10s)
#   health_retries        - Consecutive failures before unhealthy
#   health_start_period   - Initialization time before checks count
#   log_driver            - Log driver: journald, k8s-file, none, passthrough
#   log_opt               - Dict of log driver options
#   ulimits               - Dict of ulimits (e.g., {"nofile": "65536:65536"})
#
# Global verification option (in local.conf):
#   CONTAINERS_VERIFY - Enable pre-pull verification for all containers ("1" to enable)
#
# SBOM/Provenance support:
#   Container image digests are automatically resolved at build time and written to:
#     /usr/share/containers/container-digests.json
#
#   This manifest includes for each container:
#     - Original image reference (tag)
#     - Resolved SHA256 digest
#     - Build timestamp
#     - OCI labels (title, version, revision, source, licenses)
#
#   Use this file for:
#     - Software Bill of Materials (SBOM) generation
#     - Build provenance/reproducibility tracking
#     - Vulnerability scanning with pinned digests
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
#   enabled               - Boolean to enable/disable auto-start (default: true,
#                           same behavior as container enabled: Quadlet goes to
#                           systemd-available/)
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
    containers, _, _ = parse_container_manifest(manifest_path, d)
    return [c.get('name', '') for c in containers if c.get('name')]

def get_pod_list_from_manifest(d):
    """Get list of pod names from parsed manifest."""
    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return []
    _, pods, _ = parse_container_manifest(manifest_path, d)
    return [p.get('name', '') for p in pods if p.get('name')]

def get_network_list_from_manifest(d):
    """Get list of network names from parsed manifest."""
    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return []
    _, _, networks = parse_container_manifest(manifest_path, d)
    return [n.get('name', '') for n in networks if n.get('name')]

# Python function to parse manifest and validate at parse time
python __anonymous() {
    import os

    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return

    if not os.path.exists(manifest_path):
        bb.warn("Container manifest not found: %s" % manifest_path)
        return

    # Add manifest file as a file checksum dependency so BitBake tracks changes
    # This ensures the recipe is reparsed when the manifest content changes
    d.appendVarFlag('do_install', 'file-checksums', ' ' + manifest_path + ':True')
    d.appendVarFlag('do_pull_containers', 'file-checksums', ' ' + manifest_path + ':True')
    d.appendVarFlag('do_verify_containers', 'file-checksums', ' ' + manifest_path + ':True')
    d.appendVarFlag('do_generate_quadlets', 'file-checksums', ' ' + manifest_path + ':True')
    d.appendVarFlag('do_generate_pods', 'file-checksums', ' ' + manifest_path + ':True')
    d.appendVarFlag('do_generate_networks', 'file-checksums', ' ' + manifest_path + ':True')
    d.appendVarFlag('do_generate_import_scripts', 'file-checksums', ' ' + manifest_path + ':True')

    # Parse the manifest
    try:
        containers, pods, networks = parse_container_manifest(manifest_path, d)

        # Get pod names for validation
        pod_names = [p.get('name', '') for p in pods if p.get('name')]
        network_names = [n.get('name', '') for n in networks if n.get('name')]

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

        if networks:
            # Store parsed networks for later use
            d.setVar('NETWORK_MANIFEST_PARSED', str(networks))

            # Store network names for shell tasks
            d.setVar('NETWORKS_FROM_MANIFEST', ' '.join(network_names))

            # Validate each network
            for network in networks:
                name = network.get('name', '')
                if not name:
                    bb.fatal("Network in manifest is missing 'name' field")

                # Validate driver if specified
                driver = network.get('driver', '')
                if driver and driver not in ('bridge', 'macvlan', 'ipvlan'):
                    bb.fatal("Network '%s' has invalid driver '%s'. Must be one of: bridge, macvlan, ipvlan" %
                             (name, driver))

            bb.note("Parsed and validated %d networks from manifest: %s" %
                    (len(networks), ', '.join(network_names)))

    except Exception as e:
        bb.fatal("Failed to parse container manifest: %s" % str(e))
}

def parse_container_manifest(manifest_path, d):
    """Parse a YAML or JSON container manifest file. Returns (containers, pods, networks) tuple."""
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
        bb.fatal("Container manifest must be a dictionary with 'containers', 'pods', and/or 'networks' key")

    containers = data.get('containers', [])
    if not isinstance(containers, list):
        bb.fatal("'containers' must be a list in the manifest")

    pods = data.get('pods', [])
    if not isinstance(pods, list):
        bb.fatal("'pods' must be a list in the manifest")

    networks = data.get('networks', [])
    if not isinstance(networks, list):
        bb.fatal("'networks' must be a list in the manifest")

    return containers, pods, networks

def parse_container_manifest_containers_only(manifest_path, d):
    """Legacy wrapper that returns only containers for backward compatibility."""
    containers, _, _ = parse_container_manifest(manifest_path, d)
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
# Supports private registries with authentication and custom TLS settings
# Also resolves tags to digests for SBOM/provenance tracking
python do_verify_containers() {
    import subprocess
    import os
    import json
    from datetime import datetime

    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return

    containers, _, _ = parse_container_manifest(manifest_path, d)
    if not containers:
        return

    global_verify = d.getVar('CONTAINERS_VERIFY') == '1'
    oci_arch = get_oci_arch(d)
    workdir = d.getVar('WORKDIR')

    # Initialize resolved digests manifest for SBOM/provenance
    resolved_manifest = {
        'build_time': datetime.utcnow().isoformat() + 'Z',
        'architecture': oci_arch,
        'containers': []
    }

    for container in containers:
        container_name = container.get('name', '')
        # Check per-container or global verify flag
        container_verify = container.get('verify', False)
        if not container_verify and not global_verify:
            continue

        image = container.get('image', '')
        digest = container.get('digest', '')
        registry = container.get('registry', {}) or {}
        auth_file = registry.get('auth_secret', '')
        tls_verify = registry.get('tls_verify', True)
        cert_dir = registry.get('cert_dir', '')

        # Determine full image reference
        if digest:
            image_base = image.split(':')[0]
            full_image = f"{image_base}@{digest}"
        else:
            full_image = image

        bb.note(f"Verifying container image exists: '{container_name}' ({full_image})")

        # Build skopeo inspect command
        skopeo_args = ['skopeo', 'inspect', '--override-arch', oci_arch]

        # Authentication for private registries
        if auth_file:
            if os.path.exists(auth_file):
                skopeo_args.extend(['--authfile', auth_file])
                bb.note(f"Using auth file: {auth_file}")
            else:
                bb.warn(f"Auth file specified but not found: {auth_file}")

        # TLS options for private registries with self-signed certificates
        if tls_verify is False or str(tls_verify).lower() == 'false':
            skopeo_args.append('--tls-verify=false')
            bb.warn(f"TLS verification disabled for '{container_name}' - use only for testing")

        if cert_dir and os.path.isdir(cert_dir):
            skopeo_args.extend(['--cert-dir', cert_dir])
            bb.note(f"Using certificate directory: {cert_dir}")

        skopeo_args.append(f"docker://{full_image}")

        bb.note(f"Running: {' '.join(skopeo_args)}")

        try:
            result = subprocess.run(skopeo_args, check=True, capture_output=True, text=True)

            # Parse the inspect output to extract digest for SBOM
            try:
                inspect_data = json.loads(result.stdout)
                resolved_digest = inspect_data.get('Digest', '')
                image_name = inspect_data.get('Name', image.split(':')[0])
                repo_tags = inspect_data.get('RepoTags', [])
                created = inspect_data.get('Created', '')
                labels = inspect_data.get('Labels', {})

                # Extract tag from original image reference
                original_tag = image.split(':')[-1] if ':' in image and '@' not in image else 'latest'

                # Store resolved info for SBOM
                container_info = {
                    'name': container_name,
                    'image': image,
                    'resolved_digest': resolved_digest,
                    'resolved_image': f"{image_name}@{resolved_digest}" if resolved_digest else full_image,
                    'original_tag': original_tag,
                    'available_tags': repo_tags[:10] if repo_tags else [],  # Limit to 10 tags
                    'created': created,
                    'labels': {
                        'title': labels.get('org.opencontainers.image.title', ''),
                        'version': labels.get('org.opencontainers.image.version', ''),
                        'revision': labels.get('org.opencontainers.image.revision', ''),
                        'source': labels.get('org.opencontainers.image.source', ''),
                        'licenses': labels.get('org.opencontainers.image.licenses', ''),
                    }
                }
                resolved_manifest['containers'].append(container_info)

                if resolved_digest:
                    bb.note(f"Container image '{container_name}' resolved: {original_tag} -> {resolved_digest}")
                else:
                    bb.warn(f"Could not resolve digest for '{container_name}'")

            except json.JSONDecodeError:
                bb.warn(f"Could not parse skopeo inspect output for '{container_name}'")

            bb.note(f"Container image '{container_name}' verified: {full_image}")
        except subprocess.CalledProcessError as e:
            error_msg = e.stderr if e.stderr else str(e)
            # Provide more specific error messages based on the error
            if 'unauthorized' in error_msg.lower() or 'authentication required' in error_msg.lower():
                if auth_file:
                    bb.fatal(f"Container image verification failed for '{container_name}' ({full_image}): "
                             f"Authentication failed. Check that the auth file '{auth_file}' contains valid credentials.")
                else:
                    bb.fatal(f"Container image verification failed for '{container_name}' ({full_image}): "
                             f"Authentication required. Add 'registry.auth_secret' to the container configuration.")
            elif 'certificate' in error_msg.lower() or 'x509' in error_msg.lower():
                bb.fatal(f"Container image verification failed for '{container_name}' ({full_image}): "
                         f"TLS certificate error. Use 'registry.tls_verify: false' for self-signed certs "
                         f"or 'registry.cert_dir' to specify custom CA certificates.")
            elif 'manifest unknown' in error_msg.lower() or 'not found' in error_msg.lower():
                bb.fatal(f"Container image verification failed for '{container_name}' ({full_image}): "
                         f"Image or tag not found in registry.")
            else:
                bb.fatal(f"Container image verification failed for '{container_name}' ({full_image}): {error_msg}")

    # Write resolved digests manifest for SBOM/provenance
    if resolved_manifest['containers']:
        os.makedirs(workdir, exist_ok=True)
        manifest_file = os.path.join(workdir, 'container-digests.json')
        with open(manifest_file, 'w') as f:
            json.dump(resolved_manifest, f, indent=2)
        bb.note(f"Wrote resolved container digests to {manifest_file}")
}
addtask do_verify_containers after do_configure before do_pull_containers
do_verify_containers[network] = "1"
do_verify_containers[vardeps] = "CONTAINER_MANIFEST CONTAINERS_VERIFY"

# Pull all container images using skopeo-native
# Supports private registries with authentication and custom TLS settings
# Also resolves digests for SBOM/provenance tracking
python do_pull_containers() {
    import subprocess
    import os
    import json
    from datetime import datetime

    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        bb.note("No container manifest configured")
        return

    containers, _, _ = parse_container_manifest(manifest_path, d)
    if not containers:
        bb.note("No containers found in manifest")
        return

    workdir = d.getVar('WORKDIR')
    oci_arch = get_oci_arch(d)
    global_verify = d.getVar('CONTAINERS_VERIFY') == '1'

    # Load existing digest manifest from verification phase, or create new one
    manifest_file = os.path.join(workdir, 'container-digests.json')
    if os.path.exists(manifest_file):
        with open(manifest_file, 'r') as f:
            resolved_manifest = json.load(f)
        bb.note(f"Loaded existing digest manifest with {len(resolved_manifest.get('containers', []))} containers")
    else:
        resolved_manifest = {
            'build_time': datetime.utcnow().isoformat() + 'Z',
            'architecture': oci_arch,
            'containers': []
        }

    # Track which containers already have digest info from verification
    verified_names = {c['name'] for c in resolved_manifest.get('containers', [])}

    for container in containers:
        container_name = container.get('name', '')
        image = container.get('image', '')
        digest = container.get('digest', '')
        registry = container.get('registry', {}) or {}
        auth_file = registry.get('auth_secret', '')
        tls_verify = registry.get('tls_verify', True)
        cert_dir = registry.get('cert_dir', '')

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

        # Authentication for private registries
        if auth_file:
            if os.path.exists(auth_file):
                skopeo_args.extend(['--authfile', auth_file])
                bb.note(f"Using auth file: {auth_file}")
            else:
                bb.warn(f"Auth file specified but not found: {auth_file}")

        # TLS options for private registries with self-signed certificates
        if tls_verify is False or str(tls_verify).lower() == 'false':
            skopeo_args.append('--src-tls-verify=false')
            bb.warn(f"TLS verification disabled for '{container_name}' - use only for testing")

        if cert_dir and os.path.isdir(cert_dir):
            skopeo_args.extend(['--src-cert-dir', cert_dir])
            bb.note(f"Using certificate directory: {cert_dir}")

        # Add source and destination
        skopeo_args.append(f"docker://{full_image}")
        skopeo_args.append(f"oci:{oci_dir}:latest")

        bb.note(f"Running: {' '.join(skopeo_args)}")

        # Run skopeo
        try:
            result = subprocess.run(skopeo_args, check=True, capture_output=True, text=True)
            bb.note(f"Container image '{container_name}' pulled successfully")
        except subprocess.CalledProcessError as e:
            error_msg = e.stderr if e.stderr else str(e)
            # Provide more specific error messages based on the error
            if 'unauthorized' in error_msg.lower() or 'authentication required' in error_msg.lower():
                if auth_file:
                    bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): "
                             f"Authentication failed. Check that the auth file '{auth_file}' contains valid credentials.")
                else:
                    bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): "
                             f"Authentication required. Add 'registry.auth_secret' to the container configuration.")
            elif 'certificate' in error_msg.lower() or 'x509' in error_msg.lower():
                bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): "
                         f"TLS certificate error. Use 'registry.tls_verify: false' for self-signed certs "
                         f"or 'registry.cert_dir' to specify custom CA certificates.")
            elif 'manifest unknown' in error_msg.lower() or 'not found' in error_msg.lower():
                bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): "
                         f"Image or tag not found in registry.")
            else:
                bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): {error_msg}")

        # Post-pull verification (default behavior)
        verify_oci_image(oci_dir, container_name, full_image, d)

        # Resolve digest for containers not already verified (for SBOM/provenance)
        container_verify = container.get('verify', False)
        if container_name not in verified_names and not container_verify and not global_verify:
            bb.note(f"Resolving digest for '{container_name}' (not pre-verified)")

            # Build skopeo inspect command to get digest
            inspect_args = ['skopeo', 'inspect', '--override-arch', oci_arch]

            if auth_file and os.path.exists(auth_file):
                inspect_args.extend(['--authfile', auth_file])

            if tls_verify is False or str(tls_verify).lower() == 'false':
                inspect_args.append('--tls-verify=false')

            if cert_dir and os.path.isdir(cert_dir):
                inspect_args.extend(['--cert-dir', cert_dir])

            inspect_args.append(f"docker://{full_image}")

            try:
                inspect_result = subprocess.run(inspect_args, capture_output=True, text=True, check=True)
                inspect_data = json.loads(inspect_result.stdout)

                resolved_digest = inspect_data.get('Digest', '')
                image_name = inspect_data.get('Name', image.split(':')[0])
                repo_tags = inspect_data.get('RepoTags', [])
                created = inspect_data.get('Created', '')
                labels = inspect_data.get('Labels', {}) or {}

                original_tag = image.split(':')[-1] if ':' in image and '@' not in image else 'latest'

                container_info = {
                    'name': container_name,
                    'image': image,
                    'resolved_digest': resolved_digest,
                    'resolved_image': f"{image_name}@{resolved_digest}" if resolved_digest else full_image,
                    'original_tag': original_tag,
                    'available_tags': repo_tags[:10] if repo_tags else [],
                    'created': created,
                    'labels': {
                        'title': labels.get('org.opencontainers.image.title', ''),
                        'version': labels.get('org.opencontainers.image.version', ''),
                        'revision': labels.get('org.opencontainers.image.revision', ''),
                        'source': labels.get('org.opencontainers.image.source', ''),
                        'licenses': labels.get('org.opencontainers.image.licenses', ''),
                    }
                }
                resolved_manifest['containers'].append(container_info)

                if resolved_digest:
                    bb.note(f"Container '{container_name}' resolved: {original_tag} -> {resolved_digest}")
                else:
                    bb.warn(f"Could not resolve digest for '{container_name}'")

            except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
                bb.warn(f"Could not resolve digest for '{container_name}': {e}")

    # Write updated digest manifest for SBOM/provenance
    if resolved_manifest['containers']:
        with open(manifest_file, 'w') as f:
            json.dump(resolved_manifest, f, indent=2)
        bb.note(f"Wrote container digests manifest ({len(resolved_manifest['containers'])} containers) to {manifest_file}")
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

    containers, _, _ = parse_container_manifest(manifest_path, d)
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
            # If network matches a Quadlet-defined network, use the .network
            # suffix so Quadlet creates proper dependency ordering.
            defined_networks = get_network_list_from_manifest(d)
            if network in defined_networks:
                lines.append("Network=" + network + ".network")
            else:
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
            lines.append("PodmanArgs=--privileged")

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

        # Cgroups mode
        cgroups = container.get('cgroups', '')
        if cgroups:
            lines.append("PodmanArgs=--cgroups " + cgroups)

        # SD-Notify mode
        sdnotify = container.get('sdnotify', '')
        if sdnotify:
            lines.append("Notify=" + ("true" if sdnotify == "container" else "false"))
            if sdnotify != "conmon":
                lines.append("PodmanArgs=--sdnotify " + sdnotify)

        # Timezone
        timezone = container.get('timezone', '')
        if timezone:
            lines.append("Timezone=" + timezone)

        # Health check options
        health_cmd = container.get('health_cmd', '')
        if health_cmd:
            lines.append("HealthCmd=" + health_cmd)

        health_interval = container.get('health_interval', '')
        if health_interval:
            lines.append("HealthInterval=" + health_interval)

        health_timeout = container.get('health_timeout', '')
        if health_timeout:
            lines.append("HealthTimeout=" + health_timeout)

        health_retries = container.get('health_retries', '')
        if health_retries:
            lines.append("HealthRetries=" + str(health_retries))

        health_start_period = container.get('health_start_period', '')
        if health_start_period:
            lines.append("HealthStartPeriod=" + health_start_period)

        # Log driver
        log_driver = container.get('log_driver', '')
        if log_driver:
            lines.append("LogDriver=" + log_driver)

        # Log options
        log_opt = container.get('log_opt', {})
        if log_opt:
            if isinstance(log_opt, dict):
                for key, value in log_opt.items():
                    lines.append(f"PodmanArgs=--log-opt {key}={value}")
            elif isinstance(log_opt, list):
                for opt in log_opt:
                    lines.append("PodmanArgs=--log-opt " + opt)

        # Ulimits
        ulimits = container.get('ulimits', {})
        if ulimits:
            if isinstance(ulimits, dict):
                for key, value in ulimits.items():
                    lines.append(f"Ulimit={key}={value}")
            elif isinstance(ulimits, list):
                for ulimit in ulimits:
                    lines.append("Ulimit=" + ulimit)

        # Network aliases (DNS names within the container's network)
        network_aliases = container.get('network_aliases', [])
        if network_aliases:
            for alias in network_aliases:
                lines.append("PodmanArgs=--network-alias " + alias)

        lines.append("")

        # [Service] section
        lines.append("[Service]")
        restart = container.get('restart_policy', 'always')
        lines.append("Restart=" + restart)
        lines.append("TimeoutStartSec=900")

        # Stop timeout
        stop_timeout = container.get('stop_timeout', '')
        if stop_timeout:
            lines.append("TimeoutStopSec=" + str(stop_timeout))

        lines.append("")

        # [Install] section - always write proper WantedBy so the file works
        # as-is when moved to the active directory
        lines.append("[Install]")
        lines.append("WantedBy=multi-user.target")

        # Write the Quadlet file to active or available directory based on enabled state
        enabled = container.get('enabled', True)
        if not enabled:
            quadlet_dir = os.path.join(workdir, 'quadlets-available')
        else:
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

    _, pods, _ = parse_container_manifest(manifest_path, d)
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
            defined_networks = get_network_list_from_manifest(d)
            if network in defined_networks:
                lines.append("Network=" + network + ".network")
            else:
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

        # [Install] section - always write proper WantedBy so the file works
        # as-is when moved to the active directory
        lines.append("[Install]")
        lines.append("WantedBy=multi-user.target")

        # Write the Quadlet pod file to active or available directory based on enabled state
        enabled = pod.get('enabled', True)
        if not enabled:
            quadlet_dir = os.path.join(workdir, 'quadlets-available')
        else:
            quadlet_dir = os.path.join(workdir, 'quadlets')
        os.makedirs(quadlet_dir, exist_ok=True)
        pod_file = os.path.join(quadlet_dir, pod_name + ".pod")

        with open(pod_file, 'w') as f:
            f.write('\n'.join(lines))
            f.write('\n')

        bb.note("Generated Quadlet pod file for '%s': %s" % (pod_name, pod_file))
}

addtask do_generate_pods after do_configure before do_compile

# Generate Quadlet .network files for all networks
python do_generate_networks() {
    import os

    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return

    _, _, networks = parse_container_manifest(manifest_path, d)
    if not networks:
        return

    workdir = d.getVar('WORKDIR')

    for network in networks:
        network_name = network.get('name', '')

        # Build Quadlet network file content
        lines = []

        # [Unit] section
        lines.append("# Podman Quadlet network file for " + network_name)
        lines.append("# Auto-generated by meta-container-deploy (container-manifest)")
        lines.append("")
        lines.append("[Unit]")
        lines.append("Description=" + network_name + " network")
        lines.append("")

        # [Network] section
        lines.append("[Network]")
        lines.append("NetworkName=" + network_name)

        # Driver
        driver = network.get('driver', '')
        if driver:
            lines.append("Driver=" + driver)

        # Subnet
        subnet = network.get('subnet', '')
        if subnet:
            lines.append("Subnet=" + subnet)

        # Gateway
        gateway = network.get('gateway', '')
        if gateway:
            lines.append("Gateway=" + gateway)

        # IP range
        ip_range = network.get('ip_range', '')
        if ip_range:
            lines.append("IPRange=" + ip_range)

        # IPv6
        if network.get('ipv6'):
            lines.append("IPv6=true")

        # Internal (no external connectivity)
        if network.get('internal'):
            lines.append("Internal=true")

        # DNS servers
        dns = network.get('dns', [])
        if dns:
            for server in dns:
                lines.append("DNS=" + str(server))

        # Labels
        labels = network.get('labels', {})
        if labels:
            if isinstance(labels, dict):
                for key, value in labels.items():
                    lines.append(f"Label={key}={value}")
            elif isinstance(labels, list):
                for label in labels:
                    lines.append("Label=" + label)

        # Driver-specific options
        options = network.get('options', {})
        if options:
            if isinstance(options, dict):
                for key, value in options.items():
                    lines.append(f"Options={key}={value}")
            elif isinstance(options, list):
                for opt in options:
                    lines.append("Options=" + opt)

        lines.append("")

        # [Install] section
        lines.append("[Install]")
        lines.append("WantedBy=multi-user.target")

        # Write the Quadlet network file to active or available directory based on enabled state
        enabled = network.get('enabled', True)
        if not enabled:
            quadlet_dir = os.path.join(workdir, 'quadlets-available')
        else:
            quadlet_dir = os.path.join(workdir, 'quadlets')
        os.makedirs(quadlet_dir, exist_ok=True)
        network_file = os.path.join(quadlet_dir, network_name + ".network")

        with open(network_file, 'w') as f:
            f.write('\n'.join(lines))
            f.write('\n')

        bb.note("Generated Quadlet network file for '%s': %s" % (network_name, network_file))
}

addtask do_generate_networks after do_configure before do_compile

# Generate import scripts for all containers
python do_generate_import_scripts() {
    import os

    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return

    containers, _, _ = parse_container_manifest(manifest_path, d)
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
# Note: CONTAINERS_FROM_MANIFEST and PODS_FROM_MANIFEST are set at parse time
# from the manifest file content
do_install[vardeps] += "CONTAINERS_FROM_MANIFEST PODS_FROM_MANIFEST NETWORKS_FROM_MANIFEST"

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

        # Install Quadlet file (active or available based on enabled state)
        if [ -f "${WORKDIR}/quadlets/${CONTAINER_NAME}.container" ]; then
            install -d ${D}${QUADLET_DIR}
            install -m 0644 ${WORKDIR}/quadlets/${CONTAINER_NAME}.container \
                ${D}${QUADLET_DIR}/

            bbnote "Installed Quadlet file for container: ${CONTAINER_NAME}"
        elif [ -f "${WORKDIR}/quadlets-available/${CONTAINER_NAME}.container" ]; then
            install -d ${D}${sysconfdir}/containers/systemd-available
            install -m 0644 ${WORKDIR}/quadlets-available/${CONTAINER_NAME}.container \
                ${D}${sysconfdir}/containers/systemd-available/

            bbnote "Installed disabled Quadlet file for container: ${CONTAINER_NAME} (available, not active)"
        fi

        # Install import script
        if [ -f "${WORKDIR}/import-scripts/${CONTAINER_NAME}.sh" ]; then
            install -d ${D}${sysconfdir}/containers/import.d
            install -m 0755 ${WORKDIR}/import-scripts/${CONTAINER_NAME}.sh \
                ${D}${sysconfdir}/containers/import.d/

            bbnote "Installed import script for container: ${CONTAINER_NAME}"
        fi
    done

    # Install pod Quadlet files (active or available based on enabled state)
    MANIFEST_PODS="${PODS_FROM_MANIFEST}"
    for POD_NAME in $MANIFEST_PODS; do
        if [ -f "${WORKDIR}/quadlets/${POD_NAME}.pod" ]; then
            install -d ${D}${QUADLET_DIR}
            install -m 0644 ${WORKDIR}/quadlets/${POD_NAME}.pod \
                ${D}${QUADLET_DIR}/

            bbnote "Installed Quadlet pod file for: ${POD_NAME}"
        elif [ -f "${WORKDIR}/quadlets-available/${POD_NAME}.pod" ]; then
            install -d ${D}${sysconfdir}/containers/systemd-available
            install -m 0644 ${WORKDIR}/quadlets-available/${POD_NAME}.pod \
                ${D}${sysconfdir}/containers/systemd-available/

            bbnote "Installed disabled Quadlet pod file for: ${POD_NAME} (available, not active)"
        fi
    done

    # Install network Quadlet files (active or available based on enabled state)
    MANIFEST_NETWORKS="${NETWORKS_FROM_MANIFEST}"
    for NETWORK_NAME in $MANIFEST_NETWORKS; do
        if [ -f "${WORKDIR}/quadlets/${NETWORK_NAME}.network" ]; then
            install -d ${D}${QUADLET_DIR}
            install -m 0644 ${WORKDIR}/quadlets/${NETWORK_NAME}.network \
                ${D}${QUADLET_DIR}/

            bbnote "Installed Quadlet network file for: ${NETWORK_NAME}"
        elif [ -f "${WORKDIR}/quadlets-available/${NETWORK_NAME}.network" ]; then
            install -d ${D}${sysconfdir}/containers/systemd-available
            install -m 0644 ${WORKDIR}/quadlets-available/${NETWORK_NAME}.network \
                ${D}${sysconfdir}/containers/systemd-available/

            bbnote "Installed disabled Quadlet network file for: ${NETWORK_NAME} (available, not active)"
        fi
    done

    # Create import marker directory
    install -d ${D}${CONTAINER_IMPORT_MARKER_DIR}

    # Install container digests manifest for SBOM/provenance
    if [ -f "${WORKDIR}/container-digests.json" ]; then
        install -d ${D}${datadir}/containers
        install -m 0644 ${WORKDIR}/container-digests.json \
            ${D}${datadir}/containers/
        bbnote "Installed container digests manifest for SBOM/provenance"
    fi
}

# Set FILES to include all container, pod, and network artifacts
# Using wildcards since containers/pods/networks are determined at parse time from manifest
FILES:${PN} += "\
    ${CONTAINER_PRELOAD_DIR}/* \
    ${QUADLET_DIR}/*.container \
    ${QUADLET_DIR}/*.pod \
    ${QUADLET_DIR}/*.network \
    ${sysconfdir}/containers/systemd-available/*.container \
    ${sysconfdir}/containers/systemd-available/*.pod \
    ${sysconfdir}/containers/systemd-available/*.network \
    ${sysconfdir}/containers/import.d/*.sh \
    ${CONTAINER_IMPORT_MARKER_DIR} \
    ${datadir}/containers/container-digests.json \
"

# Disable automatic packaging of -dev, -dbg, -src, etc. since we only produce data files
PACKAGES = "${PN}"

# Deploy container-digests.json to DEPLOYDIR for external tooling/provenance
do_deploy() {
    if [ -f "${WORKDIR}/container-digests.json" ]; then
        install -d ${DEPLOYDIR}
        install -m 0644 ${WORKDIR}/container-digests.json ${DEPLOYDIR}/
        bbnote "Deployed container-digests.json to ${DEPLOYDIR}"
    fi
}
addtask do_deploy after do_install before do_build
do_deploy[dirs] = "${DEPLOYDIR}"
