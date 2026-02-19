# SPDX-License-Identifier: MIT
#
# container-localconf.bbclass - Configure containers via local.conf variables
#
# Inherit deploy class for DEPLOYDIR support
inherit deploy
#
# This class enables container configuration directly in local.conf without
# requiring individual recipe files. Ideal for dynamic container provisioning
# systems that generate local.conf at build time, or for manual configuration.
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
#   ENABLED - Set to "0" to disable auto-start (default: 1). Disabled containers
#            are still pulled and imported into Podman storage, but their Quadlet
#            files are installed to /etc/containers/systemd-available/ instead of
#            the active /etc/containers/systemd/ directory. To enable at runtime:
#              cp /etc/containers/systemd-available/<name>.container /etc/containers/systemd/
#              systemctl daemon-reload && systemctl start <name>
#   LABELS - Labels (space-separated key=value)
#   DEPENDS_ON - Container dependencies (space-separated names)
#   ENTRYPOINT - Override entrypoint
#   COMMAND - Command arguments
#   PULL_POLICY - Pull policy: always, missing, never (default: missing)
#   DIGEST - Pin to specific digest for reproducibility
#   AUTH_FILE - Path to registry auth file (Docker/Podman config.json format)
#   TLS_VERIFY - TLS certificate verification: "1" (default) or "0" to disable
#   CERT_DIR - Path to directory with custom CA certificates
#   POD - Pod name to join (container becomes a pod member)
#   VERIFY - Pre-pull verification: "1" to enable (default: "0")
#   CGROUPS - Cgroups mode: enabled, disabled, no-conmon, split
#   SDNOTIFY - SD-Notify mode: conmon, container, healthy, ignore
#   TIMEZONE - Container timezone (e.g., UTC, Europe/Rome, local)
#   STOP_TIMEOUT - Seconds to wait before force-killing (default: 10)
#   HEALTH_CMD - Health check command
#   HEALTH_INTERVAL - Interval between health checks (e.g., 30s)
#   HEALTH_TIMEOUT - Timeout for health check (e.g., 10s)
#   HEALTH_RETRIES - Consecutive failures before unhealthy
#   HEALTH_START_PERIOD - Initialization time before checks count
#   LOG_DRIVER - Log driver: journald, k8s-file, none, passthrough
#   LOG_OPT - Space-separated log driver options (key=value)
#   ULIMITS - Space-separated ulimits (e.g., nofile=65536:65536)
#
# Global verification option:
#   CONTAINERS_VERIFY - Enable pre-pull verification for all containers ("1" to enable)
#
# Pod configuration (PODS variable + POD_<name>_<VAR>):
#   PODS - Space-separated list of pod names to create
#   POD_<name>_PORTS - Port mappings for the pod
#   POD_<name>_NETWORK - Network mode for the pod
#   POD_<name>_VOLUMES - Shared volumes for pod containers
#   POD_<name>_LABELS - Labels for the pod
#   POD_<name>_DNS - DNS servers for the pod
#   POD_<name>_HOSTNAME - Hostname for the pod
#   POD_<name>_ENABLED - Set to "0" to disable pod auto-start (same behavior as
#                       container ENABLED: Quadlet goes to systemd-available/)
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

# Enable automatic rootfs expansion on first boot
# Set to "1" to include rootfs-expand package which expands the root
# filesystem to use all available storage space on first boot.
# Useful for SD card deployments where image size < target media size.
ROOTFS_EXPAND ?= "0"

# Include base dependencies
DEPENDS += "skopeo-native"
RDEPENDS:${PN} += "podman container-import"
RDEPENDS:${PN} += "${@'rootfs-expand' if d.getVar('ROOTFS_EXPAND') == '1' else ''}"

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

# Global pre-pull verification flag
CONTAINERS_VERIFY ?= "0"

# All container configuration variable suffixes
CONTAINER_VAR_SUFFIXES = "IMAGE PORTS VOLUMES ENVIRONMENT NETWORK RESTART USER WORKING_DIR DEVICES CAPS_ADD CAPS_DROP PRIVILEGED READ_ONLY MEMORY_LIMIT CPU_LIMIT ENABLED LABELS DEPENDS_ON ENTRYPOINT COMMAND PULL_POLICY DIGEST AUTH_FILE SECURITY_OPTS POD VERIFY CGROUPS SDNOTIFY TIMEZONE STOP_TIMEOUT HEALTH_CMD HEALTH_INTERVAL HEALTH_TIMEOUT HEALTH_RETRIES HEALTH_START_PERIOD LOG_DRIVER LOG_OPT ULIMITS"

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
# Enable with CONTAINERS_VERIFY = "1" or per-container CONTAINER_<name>_VERIFY = "1"
# Also resolves tags to digests for SBOM/provenance tracking
python do_verify_containers() {
    import subprocess
    import os
    import json
    from datetime import datetime

    containers = get_container_list(d)
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

    for container_name in containers:
        # Check per-container or global verify flag
        container_verify = get_container_var(d, container_name, 'VERIFY')
        if container_verify != '1' and not global_verify:
            continue

        image = get_container_var(d, container_name, 'IMAGE')
        digest = get_container_var(d, container_name, 'DIGEST')
        auth_file = get_container_var(d, container_name, 'AUTH_FILE')
        tls_verify = get_container_var(d, container_name, 'TLS_VERIFY')
        cert_dir = get_container_var(d, container_name, 'CERT_DIR')

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
        if tls_verify == '0':
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
                             f"Authentication required. Add 'CONTAINER_{container_name}_AUTH_FILE' to your configuration.")
            elif 'certificate' in error_msg.lower() or 'x509' in error_msg.lower():
                bb.fatal(f"Container image verification failed for '{container_name}' ({full_image}): "
                         f"TLS certificate error. Set 'CONTAINER_{container_name}_TLS_VERIFY = \"0\"' for self-signed certs "
                         f"or 'CONTAINER_{container_name}_CERT_DIR' to specify custom CA certificates.")
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
do_verify_containers[vardeps] = "CONTAINERS CONTAINERS_VERIFY"

# Pull all container images using skopeo-native
# Supports private registries with authentication and custom TLS settings
# Also resolves digests for SBOM/provenance tracking
python do_pull_containers() {
    import subprocess
    import os
    import json
    from datetime import datetime

    containers = get_container_list(d)
    if not containers:
        bb.note("No containers configured in CONTAINERS variable")
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

    for container_name in containers:
        image = get_container_var(d, container_name, 'IMAGE')
        digest = get_container_var(d, container_name, 'DIGEST')
        auth_file = get_container_var(d, container_name, 'AUTH_FILE')
        tls_verify = get_container_var(d, container_name, 'TLS_VERIFY')
        cert_dir = get_container_var(d, container_name, 'CERT_DIR')

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
        if tls_verify == '0':
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
                             f"Authentication required. Add 'CONTAINER_{container_name}_AUTH_FILE' to your configuration.")
            elif 'certificate' in error_msg.lower() or 'x509' in error_msg.lower():
                bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): "
                         f"TLS certificate error. Set 'CONTAINER_{container_name}_TLS_VERIFY = \"0\"' for self-signed certs "
                         f"or 'CONTAINER_{container_name}_CERT_DIR' to specify custom CA certificates.")
            elif 'manifest unknown' in error_msg.lower() or 'not found' in error_msg.lower():
                bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): "
                         f"Image or tag not found in registry.")
            else:
                bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): {error_msg}")

        # Post-pull verification (default behavior)
        verify_oci_image(oci_dir, container_name, full_image, d)

        # Resolve digest for containers not already verified (for SBOM/provenance)
        container_verify = get_container_var(d, container_name, 'VERIFY')
        if container_name not in verified_names and container_verify != '1' and not global_verify:
            bb.note(f"Resolving digest for '{container_name}' (not pre-verified)")

            # Build skopeo inspect command to get digest
            inspect_args = ['skopeo', 'inspect', '--override-arch', oci_arch]

            if auth_file and os.path.exists(auth_file):
                inspect_args.extend(['--authfile', auth_file])

            if tls_verify == '0':
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

        # Cgroups mode
        cgroups = get_container_var(d, container_name, 'CGROUPS')
        if cgroups:
            lines.append("PodmanArgs=--cgroups " + cgroups)

        # SD-Notify mode
        sdnotify = get_container_var(d, container_name, 'SDNOTIFY')
        if sdnotify:
            lines.append("Notify=" + ("true" if sdnotify == "container" else "false"))
            if sdnotify != "conmon":
                lines.append("PodmanArgs=--sdnotify " + sdnotify)

        # Timezone
        timezone = get_container_var(d, container_name, 'TIMEZONE')
        if timezone:
            lines.append("Timezone=" + timezone)

        # Health check options
        health_cmd = get_container_var(d, container_name, 'HEALTH_CMD')
        if health_cmd:
            lines.append("HealthCmd=" + health_cmd)

        health_interval = get_container_var(d, container_name, 'HEALTH_INTERVAL')
        if health_interval:
            lines.append("HealthInterval=" + health_interval)

        health_timeout = get_container_var(d, container_name, 'HEALTH_TIMEOUT')
        if health_timeout:
            lines.append("HealthTimeout=" + health_timeout)

        health_retries = get_container_var(d, container_name, 'HEALTH_RETRIES')
        if health_retries:
            lines.append("HealthRetries=" + health_retries)

        health_start_period = get_container_var(d, container_name, 'HEALTH_START_PERIOD')
        if health_start_period:
            lines.append("HealthStartPeriod=" + health_start_period)

        # Log driver
        log_driver = get_container_var(d, container_name, 'LOG_DRIVER')
        if log_driver:
            lines.append("LogDriver=" + log_driver)

        # Log options
        log_opt = get_container_var(d, container_name, 'LOG_OPT')
        if log_opt:
            for opt in log_opt.split():
                if '=' in opt:
                    lines.append("PodmanArgs=--log-opt " + opt)

        # Ulimits
        ulimits = get_container_var(d, container_name, 'ULIMITS')
        if ulimits:
            for ulimit in ulimits.split():
                lines.append("Ulimit=" + ulimit)

        lines.append("")

        # [Service] section
        lines.append("[Service]")
        restart = get_container_var(d, container_name, 'RESTART', 'always')
        lines.append("Restart=" + restart)
        lines.append("TimeoutStartSec=900")

        # Stop timeout
        stop_timeout = get_container_var(d, container_name, 'STOP_TIMEOUT')
        if stop_timeout:
            lines.append("TimeoutStopSec=" + stop_timeout)

        lines.append("")

        # [Install] section - always write proper WantedBy so the file works
        # as-is when moved to the active directory
        lines.append("[Install]")
        lines.append("WantedBy=multi-user.target")

        # Write the Quadlet file to active or available directory based on enabled state
        enabled = get_container_var(d, container_name, 'ENABLED', '1')
        if enabled == '0':
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

        # [Install] section - always write proper WantedBy so the file works
        # as-is when moved to the active directory
        lines.append("[Install]")
        lines.append("WantedBy=multi-user.target")

        # Write the Quadlet pod file to active or available directory based on enabled state
        enabled = get_pod_var(d, pod_name, 'ENABLED', '1')
        if enabled == '0':
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
    for POD_NAME in ${PODS}; do
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

# Set FILES to include all container and pod artifacts
# Using wildcards since containers/pods are determined at parse time
FILES:${PN} += "\
    ${CONTAINER_PRELOAD_DIR}/* \
    ${QUADLET_DIR}/*.container \
    ${QUADLET_DIR}/*.pod \
    ${sysconfdir}/containers/systemd-available/*.container \
    ${sysconfdir}/containers/systemd-available/*.pod \
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
