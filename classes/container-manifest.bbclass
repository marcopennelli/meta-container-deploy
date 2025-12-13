# SPDX-License-Identifier: MIT
#
# container-manifest.bbclass - Parse YAML/JSON container manifests
#
# This class parses a container manifest file (YAML or JSON) and dynamically
# creates recipes for each container defined. It combines container-image
# and container-quadlet functionality for declarative container deployment.
#
# Usage:
#   In local.conf or image recipe:
#     CONTAINER_MANIFEST = "${TOPDIR}/../containers.yaml"
#     inherit container-manifest
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
#
#     - name: node-red
#       image: docker.io/nodered/node-red:latest
#       ports:
#         - "1880:1880"
#       depends_on:
#         - mqtt-broker
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>
# SPDX-License-Identifier: MIT

DEPENDS += "python3-pyyaml-native"

# Manifest file location
CONTAINER_MANIFEST ?= ""

# Python function to parse manifest and set variables
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
        containers = parse_container_manifest(manifest_path, d)
        if containers:
            # Store parsed containers for later use
            d.setVar('CONTAINER_MANIFEST_PARSED', str(containers))
            bb.note("Parsed %d containers from manifest" % len(containers))
    except Exception as e:
        bb.fatal("Failed to parse container manifest: %s" % str(e))
}

def parse_container_manifest(manifest_path, d):
    """Parse a YAML or JSON container manifest file."""
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
        bb.fatal("Container manifest must be a dictionary with 'containers' key")

    containers = data.get('containers', [])
    if not isinstance(containers, list):
        bb.fatal("'containers' must be a list in the manifest")

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

# Generate IMAGE_INSTALL entries for all containers in manifest
python generate_container_packages() {
    manifest_path = d.getVar('CONTAINER_MANIFEST')
    if not manifest_path:
        return

    names = get_container_names_from_manifest(manifest_path)
    packages = []
    for name in names:
        packages.append('container-image-%s' % name)
        packages.append('container-quadlet-%s' % name)

    if packages:
        current = d.getVar('IMAGE_INSTALL') or ''
        d.setVar('IMAGE_INSTALL', current + ' ' + ' '.join(packages))
}
