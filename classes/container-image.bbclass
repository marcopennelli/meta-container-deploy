# SPDX-License-Identifier: MIT
#
# container-image.bbclass - Pull container images at build time using skopeo
#
# This class provides functionality to pull OCI container images during the
# BitBake build process using skopeo-native. Images are stored in OCI format
# and can be imported into Podman storage at first boot.
#
# Usage:
#   inherit container-image
#
#   CONTAINER_IMAGE = "docker.io/eclipse-mosquitto:2.0"
#   CONTAINER_NAME = "mqtt-broker"
#   CONTAINER_PULL_POLICY ?= "missing"  # always, missing, never
#
# Optional variables:
#   CONTAINER_AUTH_FILE - Path to Docker auth config for private registries
#   CONTAINER_DIGEST - Pin to specific digest (recommended for reproducibility)
#   CONTAINER_ARCH - Target architecture (defaults to TARGET_ARCH mapping)
#   CONTAINER_VERIFY - Pre-pull verification: "1" to enable (default: "0")
#   CONTAINER_TLS_VERIFY - TLS certificate verification: "1" (default) or "0" to disable
#   CONTAINER_CERT_DIR - Path to directory with custom CA certificates
#
# Copyright (c) 2025 Marco Pennelli <marco.pennelli@technosec.net>
# SPDX-License-Identifier: MIT

DEPENDS += "skopeo-native"
RDEPENDS:${PN} += "podman"

# Container configuration variables
CONTAINER_IMAGE ?= ""
CONTAINER_NAME ?= "${PN}"
CONTAINER_PULL_POLICY ?= "missing"
CONTAINER_AUTH_FILE ?= ""
CONTAINER_DIGEST ?= ""
CONTAINER_ARCH ?= ""
CONTAINER_VERIFY ?= "0"
CONTAINER_TLS_VERIFY ?= "1"
CONTAINER_CERT_DIR ?= ""

# OCI storage locations
CONTAINER_PRELOAD_DIR = "/var/lib/containers/preloaded"
CONTAINER_IMPORT_MARKER_DIR = "/var/lib/containers/preloaded/.imported"

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
    custom_arch = d.getVar('CONTAINER_ARCH')
    if custom_arch:
        return custom_arch
    return arch_map.get(target_arch, target_arch)

# Validate required variables
python do_validate_container() {
    container_image = d.getVar('CONTAINER_IMAGE')
    container_name = d.getVar('CONTAINER_NAME')

    if not container_image:
        bb.fatal("CONTAINER_IMAGE must be set when inheriting container-image.bbclass")

    if not container_name:
        bb.fatal("CONTAINER_NAME must be set when inheriting container-image.bbclass")

    # Validate image reference format
    import re
    # Basic validation - registry/repo:tag or registry/repo@digest
    pattern = r'^([a-zA-Z0-9][-a-zA-Z0-9.]*[a-zA-Z0-9](:[0-9]+)?/)?([a-zA-Z0-9][-a-zA-Z0-9._/]*[a-zA-Z0-9])(:[a-zA-Z0-9][-a-zA-Z0-9._]*|@sha256:[a-f0-9]{64})?$'
    if not re.match(pattern, container_image):
        bb.warn("CONTAINER_IMAGE '%s' may not be a valid image reference" % container_image)
}
addtask validate_container before do_compile

# Optional pre-pull verification using skopeo inspect
# Enable with CONTAINER_VERIFY = "1"
# Supports private registries with authentication and custom TLS settings
python do_verify_container() {
    import subprocess
    import os

    verify = d.getVar('CONTAINER_VERIFY')
    if verify != '1':
        bb.note("Pre-pull verification disabled (set CONTAINER_VERIFY='1' to enable)")
        return

    container_image = d.getVar('CONTAINER_IMAGE')
    container_name = d.getVar('CONTAINER_NAME')
    container_digest = d.getVar('CONTAINER_DIGEST')
    container_auth_file = d.getVar('CONTAINER_AUTH_FILE')
    container_tls_verify = d.getVar('CONTAINER_TLS_VERIFY')
    container_cert_dir = d.getVar('CONTAINER_CERT_DIR')
    oci_arch = get_oci_arch(d)

    # Determine full image reference
    if container_digest:
        image_base = container_image.split(':')[0]
        full_image = f"{image_base}@{container_digest}"
    else:
        full_image = container_image

    bb.note(f"Verifying container image exists: {full_image}")

    # Build skopeo inspect command
    skopeo_args = ['skopeo', 'inspect', '--override-arch', oci_arch]

    # Authentication for private registries
    if container_auth_file:
        if os.path.exists(container_auth_file):
            skopeo_args.extend(['--authfile', container_auth_file])
            bb.note(f"Using auth file: {container_auth_file}")
        else:
            bb.warn(f"Auth file specified but not found: {container_auth_file}")

    # TLS options for private registries with self-signed certificates
    if container_tls_verify == '0':
        skopeo_args.append('--tls-verify=false')
        bb.warn(f"TLS verification disabled for '{container_name}' - use only for testing")

    if container_cert_dir and os.path.isdir(container_cert_dir):
        skopeo_args.extend(['--cert-dir', container_cert_dir])
        bb.note(f"Using certificate directory: {container_cert_dir}")

    skopeo_args.append(f"docker://{full_image}")

    bb.note(f"Running: {' '.join(skopeo_args)}")

    try:
        result = subprocess.run(skopeo_args, check=True, capture_output=True, text=True)
        bb.note(f"Container image '{container_name}' verified: {full_image}")
    except subprocess.CalledProcessError as e:
        error_msg = e.stderr if e.stderr else str(e)
        # Provide more specific error messages based on the error
        if 'unauthorized' in error_msg.lower() or 'authentication required' in error_msg.lower():
            if container_auth_file:
                bb.fatal(f"Container image verification failed for '{container_name}' ({full_image}): "
                         f"Authentication failed. Check that the auth file '{container_auth_file}' contains valid credentials.")
            else:
                bb.fatal(f"Container image verification failed for '{container_name}' ({full_image}): "
                         f"Authentication required. Set 'CONTAINER_AUTH_FILE' to your registry auth config.")
        elif 'certificate' in error_msg.lower() or 'x509' in error_msg.lower():
            bb.fatal(f"Container image verification failed for '{container_name}' ({full_image}): "
                     f"TLS certificate error. Set 'CONTAINER_TLS_VERIFY = \"0\"' for self-signed certs "
                     f"or 'CONTAINER_CERT_DIR' to specify custom CA certificates.")
        elif 'manifest unknown' in error_msg.lower() or 'not found' in error_msg.lower():
            bb.fatal(f"Container image verification failed for '{container_name}' ({full_image}): "
                     f"Image or tag not found in registry.")
        else:
            bb.fatal(f"Container image verification failed for '{container_name}' ({full_image}): {error_msg}")
}
addtask do_verify_container after do_validate_container before do_pull_container
do_verify_container[network] = "1"
do_verify_container[vardeps] = "CONTAINER_IMAGE CONTAINER_NAME CONTAINER_DIGEST CONTAINER_AUTH_FILE CONTAINER_VERIFY CONTAINER_TLS_VERIFY CONTAINER_CERT_DIR"

# Pull container image using skopeo-native
# This is a separate task that requires network access
# Supports private registries with authentication and custom TLS settings
python do_pull_container() {
    import subprocess
    import os

    container_image = d.getVar('CONTAINER_IMAGE')
    container_name = d.getVar('CONTAINER_NAME')
    container_digest = d.getVar('CONTAINER_DIGEST')
    container_auth_file = d.getVar('CONTAINER_AUTH_FILE')
    container_tls_verify = d.getVar('CONTAINER_TLS_VERIFY')
    container_cert_dir = d.getVar('CONTAINER_CERT_DIR')
    workdir = d.getVar('WORKDIR')
    oci_arch = get_oci_arch(d)

    # Determine full image reference
    if container_digest:
        # Strip tag if present and use digest
        image_base = container_image.split(':')[0]
        full_image = f"{image_base}@{container_digest}"
    else:
        full_image = container_image

    bb.note(f"Pulling container image: {full_image}")
    bb.note(f"Target OCI architecture: {oci_arch}")

    # Create storage directory
    oci_dir = os.path.join(workdir, 'container-oci', container_name)
    os.makedirs(oci_dir, exist_ok=True)

    # Build skopeo command
    skopeo_args = ['skopeo', 'copy', '--override-arch', oci_arch]

    # Authentication for private registries
    if container_auth_file:
        if os.path.exists(container_auth_file):
            skopeo_args.extend(['--authfile', container_auth_file])
            bb.note(f"Using auth file: {container_auth_file}")
        else:
            bb.warn(f"Auth file specified but not found: {container_auth_file}")

    # TLS options for private registries with self-signed certificates
    if container_tls_verify == '0':
        skopeo_args.append('--src-tls-verify=false')
        bb.warn(f"TLS verification disabled for '{container_name}' - use only for testing")

    if container_cert_dir and os.path.isdir(container_cert_dir):
        skopeo_args.extend(['--src-cert-dir', container_cert_dir])
        bb.note(f"Using certificate directory: {container_cert_dir}")

    # Add source and destination
    skopeo_args.append(f"docker://{full_image}")
    skopeo_args.append(f"oci:{oci_dir}:latest")

    bb.note(f"Running: {' '.join(skopeo_args)}")

    # Run skopeo
    try:
        result = subprocess.run(skopeo_args, check=True, capture_output=True, text=True)
        bb.note(f"Container image {container_name} pulled successfully")
    except subprocess.CalledProcessError as e:
        error_msg = e.stderr if e.stderr else str(e)
        # Provide more specific error messages based on the error
        if 'unauthorized' in error_msg.lower() or 'authentication required' in error_msg.lower():
            if container_auth_file:
                bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): "
                         f"Authentication failed. Check that the auth file '{container_auth_file}' contains valid credentials.")
            else:
                bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): "
                         f"Authentication required. Set 'CONTAINER_AUTH_FILE' to your registry auth config.")
        elif 'certificate' in error_msg.lower() or 'x509' in error_msg.lower():
            bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): "
                     f"TLS certificate error. Set 'CONTAINER_TLS_VERIFY = \"0\"' for self-signed certs "
                     f"or 'CONTAINER_CERT_DIR' to specify custom CA certificates.")
        elif 'manifest unknown' in error_msg.lower() or 'not found' in error_msg.lower():
            bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): "
                     f"Image or tag not found in registry.")
        else:
            bb.fatal(f"Failed to pull container image '{container_name}' ({full_image}): {error_msg}")

    # Post-pull verification (default behavior)
    verify_oci_image(oci_dir, container_name, full_image, d)
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

addtask do_pull_container after do_configure before do_compile
do_pull_container[network] = "1"
do_pull_container[vardeps] = "CONTAINER_IMAGE CONTAINER_NAME CONTAINER_DIGEST CONTAINER_AUTH_FILE CONTAINER_TLS_VERIFY CONTAINER_CERT_DIR"

# Install container image and import script (appends to do_install)
do_install:append() {
    CONTAINER_NAME="${CONTAINER_NAME}"
    CONTAINER_IMAGE="${CONTAINER_IMAGE}"

    # Install OCI image directory
    install -d ${D}${CONTAINER_PRELOAD_DIR}
    cp -r ${WORKDIR}/container-oci/${CONTAINER_NAME} \
        ${D}${CONTAINER_PRELOAD_DIR}/

    # Create import marker directory
    install -d ${D}${CONTAINER_IMPORT_MARKER_DIR}

    # Create per-container import script
    install -d ${D}${sysconfdir}/containers/import.d
    cat > ${D}${sysconfdir}/containers/import.d/${CONTAINER_NAME}.sh << 'IMPORT_EOF'
#!/bin/sh
# Import container image: ${CONTAINER_NAME}
# Source image: ${CONTAINER_IMAGE}

CONTAINER_NAME="${CONTAINER_NAME}"
CONTAINER_IMAGE="${CONTAINER_IMAGE}"
IMAGE_DIR="${CONTAINER_PRELOAD_DIR}/${CONTAINER_NAME}"
MARKER_FILE="${CONTAINER_IMPORT_MARKER_DIR}/${CONTAINER_NAME}"

if [ -d "$IMAGE_DIR" ] && [ ! -f "$MARKER_FILE" ]; then
    echo "Importing container image: ${CONTAINER_IMAGE}"

    # Import using skopeo (preferred) or podman load
    if command -v skopeo >/dev/null 2>&1; then
        skopeo copy oci:"$IMAGE_DIR":latest containers-storage:"${CONTAINER_IMAGE}"
    else
        # Fallback to podman if skopeo not available at runtime
        podman load -i "$IMAGE_DIR"
    fi

    if [ $? -eq 0 ]; then
        touch "$MARKER_FILE"
        echo "Container image ${CONTAINER_NAME} imported successfully"
    else
        echo "Failed to import container image ${CONTAINER_NAME}" >&2
        exit 1
    fi
else
    if [ -f "$MARKER_FILE" ]; then
        echo "Container image ${CONTAINER_NAME} already imported"
    else
        echo "Container image directory not found: $IMAGE_DIR" >&2
        exit 1
    fi
fi
IMPORT_EOF
    chmod 0755 ${D}${sysconfdir}/containers/import.d/${CONTAINER_NAME}.sh

    # Substitute variables in the script
    sed -i "s|\${CONTAINER_NAME}|${CONTAINER_NAME}|g" \
        ${D}${sysconfdir}/containers/import.d/${CONTAINER_NAME}.sh
    sed -i "s|\${CONTAINER_IMAGE}|${CONTAINER_IMAGE}|g" \
        ${D}${sysconfdir}/containers/import.d/${CONTAINER_NAME}.sh
    sed -i "s|\${CONTAINER_PRELOAD_DIR}|${CONTAINER_PRELOAD_DIR}|g" \
        ${D}${sysconfdir}/containers/import.d/${CONTAINER_NAME}.sh
    sed -i "s|\${CONTAINER_IMPORT_MARKER_DIR}|${CONTAINER_IMPORT_MARKER_DIR}|g" \
        ${D}${sysconfdir}/containers/import.d/${CONTAINER_NAME}.sh
}

# Package files - use :append to allow combining with other bbclasses
FILES:${PN}:append = " \
    ${CONTAINER_PRELOAD_DIR}/${CONTAINER_NAME} \
    ${CONTAINER_IMPORT_MARKER_DIR} \
    ${sysconfdir}/containers/import.d/${CONTAINER_NAME}.sh \
"

# Ensure runtime dependencies
RDEPENDS:${PN} += "container-import"
