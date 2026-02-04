# Changelog

All notable changes to the meta-container-deploy layer are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## 2026-02-03

### Added
- **SBOM/Provenance support**: Automatic digest resolution at build time for all configuration methods ([61cf61a], [f6b8e0f])
- Container image tags are resolved to immutable SHA256 digests
- Digest manifest written to `/usr/share/containers/container-digests.json`
- Digest manifest deployed to `DEPLOYDIR` for external CI/CD tooling ([fcb7aa2])
- OCI labels extraction (title, version, revision, source, licenses)

### Fixed
- Inherit deploy class for proper DEPLOYDIR support ([f0e5d64])
- Company attribution in LICENSE file ([7d0ecc3])

## 2026-01-28

### Added
- **Private registry support**: Authentication, TLS verification, and custom CA certificates ([81d863b], [ee54d23])
- `AUTH_FILE` / `auth_secret` for registry authentication
- `TLS_VERIFY` option to disable certificate verification for self-signed certs
- `CERT_DIR` for custom CA certificate directories
- Improved error messages for authentication and TLS failures

### Changed
- Documentation updated with private registry configuration examples ([2c8e36f])

## 2026-01-25

### Added
- **Advanced container options** across all configuration methods ([ef413a5]):
  - Health checks (command, interval, timeout, retries, start_period)
  - Security options (seccomp, apparmor, selinux, no_new_privileges)
  - Resource limits (memory, CPU, ulimits, pids_limit)
  - Logging configuration (driver, options)
  - DNS settings (servers, search domains, options)
  - Additional mounts (tmpfs, bind propagation)

### Fixed
- rootfs-expand: Fixed arithmetic errors with lsblk output ([e2d0cb5])
- rootfs-expand: Use `-d` flag to get device size without children ([4463915])
- rootfs-expand: Ensure kernel sees new partition size before filesystem resize ([932a7e7])

## 2026-01-22

### Fixed
- rootfs-expand: Use sfdisk instead of cloud-utils-growpart as fallback ([19a98d5])
- rootfs-expand: Use shell arithmetic instead of bc for portability ([77c7476])

## 2026-01-21

### Added
- **rootfs-expand recipe**: Automatic root filesystem expansion on first boot ([939789e])
- Supports ext2/ext3/ext4, btrfs, xfs, and f2fs filesystems
- Supports SD cards (mmcblk), NVMe, and SATA/USB drives
- Systemd service for automatic execution

## 2026-01-20

### Added
- **Container image verification**: Pre-pull and post-pull verification ([4435134])
- Pre-pull verification using `skopeo inspect` (optional, enable with `CONTAINER_VERIFY`)
- Post-pull verification of OCI structure (default)
- Deterministic task hashes with file-checksums and vardeps ([091780b])

### Changed
- Skopeo output now flows to task logs for better debugging ([7d9590f])

## 2026-01-13

### Added
- **Podman pod support**: Atomic multi-container deployments ([d38683a])
- Pod definitions in YAML manifests
- Quadlet `.pod` file generation
- Shared networking, volumes, and resource limits for pods

## 2025-12-13

### Added
- Initial release of meta-container-deploy layer ([0f985f1])
- **Four configuration methods**:
  - Method 1: Direct recipe using `container-image.bbclass`
  - Method 2: local.conf variables using `container-localconf.bbclass`
  - Method 3: YAML/JSON manifest using `container-manifest.bbclass`
  - Method 4: Packagegroup combining multiple container recipes
- OCI image pulling at build time using skopeo-native
- Quadlet `.container` file generation for systemd integration
- First-boot container import service
- Support for Yocto Scarthgap and Styhead releases

[Unreleased]: https://github.com/marcopennelli/meta-container-deploy/compare/main...HEAD
[0f985f1]: https://github.com/marcopennelli/meta-container-deploy/commit/0f985f1
[d38683a]: https://github.com/marcopennelli/meta-container-deploy/commit/d38683a
[7d9590f]: https://github.com/marcopennelli/meta-container-deploy/commit/7d9590f
[4435134]: https://github.com/marcopennelli/meta-container-deploy/commit/4435134
[091780b]: https://github.com/marcopennelli/meta-container-deploy/commit/091780b
[939789e]: https://github.com/marcopennelli/meta-container-deploy/commit/939789e
[77c7476]: https://github.com/marcopennelli/meta-container-deploy/commit/77c7476
[19a98d5]: https://github.com/marcopennelli/meta-container-deploy/commit/19a98d5
[ef413a5]: https://github.com/marcopennelli/meta-container-deploy/commit/ef413a5
[e2d0cb5]: https://github.com/marcopennelli/meta-container-deploy/commit/e2d0cb5
[4463915]: https://github.com/marcopennelli/meta-container-deploy/commit/4463915
[932a7e7]: https://github.com/marcopennelli/meta-container-deploy/commit/932a7e7
[81d863b]: https://github.com/marcopennelli/meta-container-deploy/commit/81d863b
[ee54d23]: https://github.com/marcopennelli/meta-container-deploy/commit/ee54d23
[2c8e36f]: https://github.com/marcopennelli/meta-container-deploy/commit/2c8e36f
[7d0ecc3]: https://github.com/marcopennelli/meta-container-deploy/commit/7d0ecc3
[61cf61a]: https://github.com/marcopennelli/meta-container-deploy/commit/61cf61a
[f6b8e0f]: https://github.com/marcopennelli/meta-container-deploy/commit/f6b8e0f
[fcb7aa2]: https://github.com/marcopennelli/meta-container-deploy/commit/fcb7aa2
[f0e5d64]: https://github.com/marcopennelli/meta-container-deploy/commit/f0e5d64
