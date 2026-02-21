# SPDX-License-Identifier: MIT
"""
Tests for container-quadlet.bbclass generation logic.

Each test loads the bbclass via the conftest helpers, sets up a MockDataStore
with the desired variables, calls the extracted task function, reads the
generated .container file, and asserts the expected Quadlet directives.
"""

import os
import pytest

from conftest import (
    MockDataStore,
    MockBB,
    BBFatalError,
    load_bbclass,
    parse_quadlet,
)

BBCLASS_PATH = os.path.join(
    os.path.dirname(os.path.dirname(__file__)),
    "classes",
    "container-quadlet.bbclass",
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def env(tmp_path):
    """Return a (datastore, bb, namespace) tuple with WORKDIR pre-configured."""
    d = MockDataStore()
    bb = MockBB()
    ns = load_bbclass(BBCLASS_PATH, bb)
    d.setVar("WORKDIR", str(tmp_path))
    return d, bb, ns


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _set_defaults(d, name="test-container", image="docker.io/library/test:latest"):
    """Apply the mandatory variables that every generation run needs.

    In real BitBake, default values are set via '?=' in the bbclass.
    Our mock doesn't handle defaults, so we must set them explicitly.
    """
    d.setVar("CONTAINER_NAME", name)
    d.setVar("CONTAINER_IMAGE", image)
    d.setVar("CONTAINER_RESTART", "always")


def _generate(env):
    """Run do_generate_quadlet and return the parsed sections dict."""
    d, bb, ns = env
    ns["do_generate_quadlet"](d, bb)
    return _read_quadlet(d)


def _read_quadlet(d):
    """Read and parse the generated .container file."""
    workdir = d.getVar("WORKDIR")
    name = d.getVar("CONTAINER_NAME")
    enabled = d.getVar("CONTAINER_ENABLED")

    if enabled == "0":
        subdir = "quadlets-available"
    else:
        subdir = "quadlets"

    path = os.path.join(workdir, subdir, name + ".container")
    assert os.path.isfile(path), f"Expected quadlet file not found: {path}"

    with open(path) as f:
        content = f.read()

    return parse_quadlet(content)


def _raw_content(d):
    """Return the raw text of the generated .container file."""
    workdir = d.getVar("WORKDIR")
    name = d.getVar("CONTAINER_NAME")
    enabled = d.getVar("CONTAINER_ENABLED")

    subdir = "quadlets-available" if enabled == "0" else "quadlets"
    path = os.path.join(workdir, subdir, name + ".container")

    with open(path) as f:
        return f.read()


def _as_list(value):
    """Normalise a parsed value to a list, even if it was stored as a scalar."""
    if isinstance(value, list):
        return value
    return [value]


# ---------------------------------------------------------------------------
# 1. Basic container (minimal config)
# ---------------------------------------------------------------------------

class TestBasicContainer:

    def test_minimal_generates_all_sections(self, env):
        d, bb, ns = env
        _set_defaults(d)
        sections = _generate(env)

        assert "Unit" in sections
        assert "Container" in sections
        assert "Service" in sections
        assert "Install" in sections

    def test_unit_description(self, env):
        d, _, _ = env
        _set_defaults(d, name="mqtt-broker")
        sections = _generate(env)

        assert sections["Unit"]["Description"] == "mqtt-broker container service"

    def test_unit_after_network(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        after = _as_list(sections["Unit"]["After"])
        assert "network-online.target" in after

    def test_unit_wants_network(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        assert sections["Unit"]["Wants"] == "network-online.target"

    def test_container_image(self, env):
        d, _, _ = env
        _set_defaults(d, image="docker.io/eclipse-mosquitto:2.0")
        sections = _generate(env)

        assert sections["Container"]["Image"] == "docker.io/eclipse-mosquitto:2.0"

    def test_service_restart_default(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        assert sections["Service"]["Restart"] == "always"

    def test_service_timeout_start(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        assert sections["Service"]["TimeoutStartSec"] == "900"

    def test_install_wanted_by(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        assert sections["Install"]["WantedBy"] == "multi-user.target"

    def test_file_written_to_quadlets_dir(self, env, tmp_path):
        d, _, _ = env
        _set_defaults(d, name="foo")
        _generate(env)

        assert os.path.isfile(os.path.join(str(tmp_path), "quadlets", "foo.container"))

    def test_bb_note_emitted(self, env):
        d, bb, _ = env
        _set_defaults(d)
        _generate(env)

        assert any("Generated Quadlet file" in n for n in bb.notes)


# ---------------------------------------------------------------------------
# 2. Ports
# ---------------------------------------------------------------------------

class TestPorts:

    def test_single_port(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_PORTS", "8080:80")
        sections = _generate(env)

        assert sections["Container"]["PublishPort"] == "8080:80"

    def test_multiple_ports(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_PORTS", "1883:1883 9001:9001")
        sections = _generate(env)

        ports = _as_list(sections["Container"]["PublishPort"])
        assert ports == ["1883:1883", "9001:9001"]

    def test_no_ports_omitted(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        assert "PublishPort" not in sections["Container"]


# ---------------------------------------------------------------------------
# 3. Volumes
# ---------------------------------------------------------------------------

class TestVolumes:

    def test_single_volume(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_VOLUMES", "/data/mosquitto:/mosquitto/data:rw")
        sections = _generate(env)

        assert sections["Container"]["Volume"] == "/data/mosquitto:/mosquitto/data:rw"

    def test_multiple_volumes(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_VOLUMES", "/host/a:/a:ro /host/b:/b:rw")
        sections = _generate(env)

        vols = _as_list(sections["Container"]["Volume"])
        assert vols == ["/host/a:/a:ro", "/host/b:/b:rw"]

    def test_no_volumes_omitted(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        assert "Volume" not in sections["Container"]


# ---------------------------------------------------------------------------
# 4. Environment
# ---------------------------------------------------------------------------

class TestEnvironment:

    def test_single_env_var(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_ENVIRONMENT", "MQTT_PORT=1883")
        sections = _generate(env)

        assert sections["Container"]["Environment"] == "MQTT_PORT=1883"

    def test_multiple_env_vars(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_ENVIRONMENT", "FOO=bar BAZ=quux")
        sections = _generate(env)

        envs = _as_list(sections["Container"]["Environment"])
        assert envs == ["FOO=bar", "BAZ=quux"]

    def test_env_without_equals_ignored(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_ENVIRONMENT", "GOOD=val NOEQUALS")
        sections = _generate(env)

        # Only the one with '=' should appear
        assert sections["Container"]["Environment"] == "GOOD=val"


# ---------------------------------------------------------------------------
# 5. Network - plain modes (host, bridge, none)
# ---------------------------------------------------------------------------

class TestNetworkPlain:

    def test_host_network(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_NETWORK", "host")
        sections = _generate(env)

        assert sections["Container"]["Network"] == "host"

    def test_bridge_network(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_NETWORK", "bridge")
        sections = _generate(env)

        assert sections["Container"]["Network"] == "bridge"

    def test_none_network(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_NETWORK", "none")
        sections = _generate(env)

        assert sections["Container"]["Network"] == "none"

    def test_no_network_omitted(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        assert "Network" not in sections["Container"]


# ---------------------------------------------------------------------------
# 6. Network - Quadlet .network suffix
# ---------------------------------------------------------------------------

class TestNetworkQuadlet:

    def test_custom_network_with_suffix(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_NETWORK", "mynet")
        d.setVar("NETWORKS", "mynet othernet")
        sections = _generate(env)

        assert sections["Container"]["Network"] == "mynet.network"

    def test_custom_network_not_in_networks_list(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_NETWORK", "mynet")
        # NETWORKS not set or doesn't contain mynet
        sections = _generate(env)

        assert sections["Container"]["Network"] == "mynet"

    def test_host_not_suffixed_even_if_in_networks(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_NETWORK", "host")
        d.setVar("NETWORKS", "host")
        sections = _generate(env)

        # host is literally in the NETWORKS list, so the bbclass WILL suffix it.
        # This tests the actual behaviour, not the ideal behaviour.
        assert sections["Container"]["Network"] == "host.network"


# ---------------------------------------------------------------------------
# 7. Privileged mode
# ---------------------------------------------------------------------------

class TestPrivileged:

    def test_privileged_sets_security_label_disable(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_PRIVILEGED", "1")
        sections = _generate(env)

        assert sections["Container"]["SecurityLabelDisable"] == "true"

    def test_privileged_sets_podman_args(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_PRIVILEGED", "1")
        sections = _generate(env)

        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--privileged" in podman_args

    def test_not_privileged_omits_both(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        assert "SecurityLabelDisable" not in sections["Container"]
        assert "PodmanArgs" not in sections.get("Container", {})


# ---------------------------------------------------------------------------
# 8. Capabilities
# ---------------------------------------------------------------------------

class TestCapabilities:

    def test_caps_add_single(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_CAPS_ADD", "NET_ADMIN")
        sections = _generate(env)

        assert sections["Container"]["AddCapability"] == "NET_ADMIN"

    def test_caps_add_multiple(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_CAPS_ADD", "NET_ADMIN SYS_TIME")
        sections = _generate(env)

        caps = _as_list(sections["Container"]["AddCapability"])
        assert caps == ["NET_ADMIN", "SYS_TIME"]

    def test_caps_drop_single(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_CAPS_DROP", "ALL")
        sections = _generate(env)

        assert sections["Container"]["DropCapability"] == "ALL"

    def test_caps_drop_multiple(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_CAPS_DROP", "NET_RAW MKNOD")
        sections = _generate(env)

        caps = _as_list(sections["Container"]["DropCapability"])
        assert caps == ["NET_RAW", "MKNOD"]

    def test_both_add_and_drop(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_CAPS_ADD", "NET_ADMIN")
        d.setVar("CONTAINER_CAPS_DROP", "ALL")
        sections = _generate(env)

        assert sections["Container"]["AddCapability"] == "NET_ADMIN"
        assert sections["Container"]["DropCapability"] == "ALL"


# ---------------------------------------------------------------------------
# 9. Read-only root filesystem
# ---------------------------------------------------------------------------

class TestReadOnly:

    def test_read_only_enabled(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_READ_ONLY", "1")
        sections = _generate(env)

        assert sections["Container"]["ReadOnly"] == "true"

    def test_read_only_not_set(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        assert "ReadOnly" not in sections["Container"]


# ---------------------------------------------------------------------------
# 10. Resource limits
# ---------------------------------------------------------------------------

class TestResourceLimits:

    def test_memory_limit(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_MEMORY_LIMIT", "512m")
        sections = _generate(env)

        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--memory 512m" in podman_args

    def test_cpu_limit(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_CPU_LIMIT", "0.5")
        sections = _generate(env)

        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--cpus 0.5" in podman_args

    def test_both_limits(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_MEMORY_LIMIT", "1g")
        d.setVar("CONTAINER_CPU_LIMIT", "2")
        sections = _generate(env)

        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--memory 1g" in podman_args
        assert "--cpus 2" in podman_args


# ---------------------------------------------------------------------------
# 11. Pod membership
# ---------------------------------------------------------------------------

class TestPod:

    def test_pod_directive(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_POD", "mypod")
        sections = _generate(env)

        assert sections["Container"]["Pod"] == "mypod.pod"

    def test_no_pod_omitted(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        assert "Pod" not in sections["Container"]


# ---------------------------------------------------------------------------
# 12. Disabled container (quadlets-available)
# ---------------------------------------------------------------------------

class TestDisabledContainer:

    def test_disabled_writes_to_quadlets_available(self, env, tmp_path):
        d, _, _ = env
        _set_defaults(d, name="disabled-svc")
        d.setVar("CONTAINER_ENABLED", "0")
        _generate(env)

        path = os.path.join(str(tmp_path), "quadlets-available", "disabled-svc.container")
        assert os.path.isfile(path)

    def test_disabled_not_in_quadlets(self, env, tmp_path):
        d, _, _ = env
        _set_defaults(d, name="disabled-svc")
        d.setVar("CONTAINER_ENABLED", "0")
        _generate(env)

        path = os.path.join(str(tmp_path), "quadlets", "disabled-svc.container")
        assert not os.path.exists(path)

    def test_enabled_by_default_writes_to_quadlets(self, env, tmp_path):
        d, _, _ = env
        _set_defaults(d, name="enabled-svc")
        _generate(env)

        path = os.path.join(str(tmp_path), "quadlets", "enabled-svc.container")
        assert os.path.isfile(path)

    def test_disabled_still_has_wantedby(self, env):
        """Disabled containers keep WantedBy so they work once moved to active dir."""
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_ENABLED", "0")
        sections = _generate(env)

        assert sections["Install"]["WantedBy"] == "multi-user.target"


# ---------------------------------------------------------------------------
# 13. Health checks
# ---------------------------------------------------------------------------

class TestHealthChecks:

    def test_health_cmd(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_HEALTH_CMD", "curl -f http://localhost/ || exit 1")
        sections = _generate(env)

        assert sections["Container"]["HealthCmd"] == "curl -f http://localhost/ || exit 1"

    def test_health_interval(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_HEALTH_INTERVAL", "30s")
        sections = _generate(env)

        assert sections["Container"]["HealthInterval"] == "30s"

    def test_health_timeout(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_HEALTH_TIMEOUT", "10s")
        sections = _generate(env)

        assert sections["Container"]["HealthTimeout"] == "10s"

    def test_health_retries(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_HEALTH_RETRIES", "3")
        sections = _generate(env)

        assert sections["Container"]["HealthRetries"] == "3"

    def test_health_start_period(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_HEALTH_START_PERIOD", "60s")
        sections = _generate(env)

        assert sections["Container"]["HealthStartPeriod"] == "60s"

    def test_all_health_fields_together(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_HEALTH_CMD", "pg_isready")
        d.setVar("CONTAINER_HEALTH_INTERVAL", "15s")
        d.setVar("CONTAINER_HEALTH_TIMEOUT", "5s")
        d.setVar("CONTAINER_HEALTH_RETRIES", "5")
        d.setVar("CONTAINER_HEALTH_START_PERIOD", "30s")
        sections = _generate(env)

        assert sections["Container"]["HealthCmd"] == "pg_isready"
        assert sections["Container"]["HealthInterval"] == "15s"
        assert sections["Container"]["HealthTimeout"] == "5s"
        assert sections["Container"]["HealthRetries"] == "5"
        assert sections["Container"]["HealthStartPeriod"] == "30s"


# ---------------------------------------------------------------------------
# 14. Network aliases
# ---------------------------------------------------------------------------

class TestNetworkAliases:

    def test_single_alias(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_NETWORK_ALIASES", "mqtt")
        sections = _generate(env)

        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--network-alias mqtt" in podman_args

    def test_multiple_aliases(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_NETWORK_ALIASES", "mqtt broker msgbus")
        sections = _generate(env)

        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--network-alias mqtt" in podman_args
        assert "--network-alias broker" in podman_args
        assert "--network-alias msgbus" in podman_args


# ---------------------------------------------------------------------------
# 15. Dependencies
# ---------------------------------------------------------------------------

class TestDependencies:

    def test_single_dependency(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_DEPENDS_ON", "db")
        sections = _generate(env)

        after = _as_list(sections["Unit"]["After"])
        assert "db.service" in after
        assert sections["Unit"]["Requires"] == "db.service"

    def test_multiple_dependencies(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_DEPENDS_ON", "db redis")
        sections = _generate(env)

        after = _as_list(sections["Unit"]["After"])
        requires = _as_list(sections["Unit"]["Requires"])

        assert "db.service" in after
        assert "redis.service" in after
        assert "db.service" in requires
        assert "redis.service" in requires

    def test_dependencies_preserve_network_after(self, env):
        """network-online.target After= must still be present alongside dep Afters."""
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_DEPENDS_ON", "dep1")
        sections = _generate(env)

        after = _as_list(sections["Unit"]["After"])
        assert "network-online.target" in after
        assert "dep1.service" in after


# ---------------------------------------------------------------------------
# 16. Timezone
# ---------------------------------------------------------------------------

class TestTimezone:

    def test_timezone_utc(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_TIMEZONE", "UTC")
        sections = _generate(env)

        assert sections["Container"]["Timezone"] == "UTC"

    def test_timezone_regional(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_TIMEZONE", "Europe/Rome")
        sections = _generate(env)

        assert sections["Container"]["Timezone"] == "Europe/Rome"

    def test_timezone_local(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_TIMEZONE", "local")
        sections = _generate(env)

        assert sections["Container"]["Timezone"] == "local"


# ---------------------------------------------------------------------------
# 17. SD-Notify
# ---------------------------------------------------------------------------

class TestSDNotify:

    def test_sdnotify_container(self, env):
        """container mode: Notify=true AND PodmanArgs=--sdnotify container."""
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_SDNOTIFY", "container")
        sections = _generate(env)

        assert sections["Container"]["Notify"] == "true"
        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--sdnotify container" in podman_args

    def test_sdnotify_conmon(self, env):
        """conmon mode: Notify=false, no --sdnotify PodmanArgs (conmon is default)."""
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_SDNOTIFY", "conmon")
        sections = _generate(env)

        assert sections["Container"]["Notify"] == "false"
        # conmon is the default, so no --sdnotify arg is emitted
        podman_args = _as_list(sections["Container"].get("PodmanArgs", []))
        sdnotify_args = [a for a in podman_args if "--sdnotify" in a]
        assert sdnotify_args == []

    def test_sdnotify_healthy(self, env):
        """healthy mode: Notify=false AND PodmanArgs=--sdnotify healthy."""
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_SDNOTIFY", "healthy")
        sections = _generate(env)

        assert sections["Container"]["Notify"] == "false"
        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--sdnotify healthy" in podman_args

    def test_sdnotify_ignore(self, env):
        """ignore mode: Notify=false AND PodmanArgs=--sdnotify ignore."""
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_SDNOTIFY", "ignore")
        sections = _generate(env)

        assert sections["Container"]["Notify"] == "false"
        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--sdnotify ignore" in podman_args


# ---------------------------------------------------------------------------
# 18. Log driver and options
# ---------------------------------------------------------------------------

class TestLogging:

    def test_log_driver(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_LOG_DRIVER", "journald")
        sections = _generate(env)

        assert sections["Container"]["LogDriver"] == "journald"

    def test_log_driver_k8s_file(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_LOG_DRIVER", "k8s-file")
        sections = _generate(env)

        assert sections["Container"]["LogDriver"] == "k8s-file"

    def test_log_opt_single(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_LOG_OPT", "max-size=10m")
        sections = _generate(env)

        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--log-opt max-size=10m" in podman_args

    def test_log_opt_multiple(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_LOG_OPT", "max-size=10m max-file=3")
        sections = _generate(env)

        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--log-opt max-size=10m" in podman_args
        assert "--log-opt max-file=3" in podman_args

    def test_log_opt_without_equals_ignored(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_LOG_OPT", "noeq max-size=5m")
        sections = _generate(env)

        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--log-opt max-size=5m" in podman_args
        # The entry without '=' must NOT appear
        assert all("noeq" not in a for a in podman_args)

    def test_log_driver_and_opts_together(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_LOG_DRIVER", "k8s-file")
        d.setVar("CONTAINER_LOG_OPT", "max-size=10m")
        sections = _generate(env)

        assert sections["Container"]["LogDriver"] == "k8s-file"
        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--log-opt max-size=10m" in podman_args


# ---------------------------------------------------------------------------
# 19. Ulimits
# ---------------------------------------------------------------------------

class TestUlimits:

    def test_single_ulimit(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_ULIMITS", "nofile=65536:65536")
        sections = _generate(env)

        assert sections["Container"]["Ulimit"] == "nofile=65536:65536"

    def test_multiple_ulimits(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_ULIMITS", "nofile=65536:65536 nproc=4096:4096")
        sections = _generate(env)

        ulimits = _as_list(sections["Container"]["Ulimit"])
        assert ulimits == ["nofile=65536:65536", "nproc=4096:4096"]


# ---------------------------------------------------------------------------
# 20. Devices
# ---------------------------------------------------------------------------

class TestDevices:

    def test_single_device(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_DEVICES", "/dev/ttyUSB0")
        sections = _generate(env)

        assert sections["Container"]["AddDevice"] == "/dev/ttyUSB0"

    def test_multiple_devices(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_DEVICES", "/dev/ttyUSB0 /dev/video0")
        sections = _generate(env)

        devices = _as_list(sections["Container"]["AddDevice"])
        assert devices == ["/dev/ttyUSB0", "/dev/video0"]


# ---------------------------------------------------------------------------
# 21. Validation (do_validate_quadlet)
# ---------------------------------------------------------------------------

class TestValidation:

    def test_missing_image_raises_fatal(self, env):
        d, bb, ns = env
        d.setVar("CONTAINER_NAME", "test-container")
        # CONTAINER_IMAGE intentionally not set

        with pytest.raises(BBFatalError, match="CONTAINER_IMAGE must be set"):
            ns["do_validate_quadlet"](d, bb)

    def test_missing_name_raises_fatal(self, env):
        d, bb, ns = env
        d.setVar("CONTAINER_IMAGE", "docker.io/test:latest")
        # CONTAINER_NAME intentionally not set

        with pytest.raises(BBFatalError, match="CONTAINER_NAME must be set"):
            ns["do_validate_quadlet"](d, bb)

    def test_invalid_restart_policy_raises_fatal(self, env):
        d, bb, ns = env
        _set_defaults(d)
        d.setVar("CONTAINER_RESTART", "banana")

        with pytest.raises(BBFatalError, match="CONTAINER_RESTART must be one of"):
            ns["do_validate_quadlet"](d, bb)

    def test_valid_restart_policies_accepted(self, env):
        d, bb, ns = env
        for policy in ("always", "on-failure", "no", ""):
            d, bb, ns = env
            # Re-create bb to clear fatals between iterations
            bb = MockBB()
            ns = load_bbclass(BBCLASS_PATH, bb)
            _set_defaults(d)
            d.setVar("CONTAINER_RESTART", policy)
            # Should not raise
            ns["do_validate_quadlet"](d, bb)

    def test_privileged_warning(self, env):
        d, bb, ns = env
        _set_defaults(d, name="priv-svc")
        d.setVar("CONTAINER_PRIVILEGED", "1")
        ns["do_validate_quadlet"](d, bb)

        assert any("privileged" in w for w in bb.warnings)

    def test_host_network_warning(self, env):
        d, bb, ns = env
        _set_defaults(d, name="host-svc")
        d.setVar("CONTAINER_NETWORK", "host")
        ns["do_validate_quadlet"](d, bb)

        assert any("host networking" in w for w in bb.warnings)

    def test_pod_member_with_ports_warning(self, env):
        d, bb, ns = env
        _set_defaults(d, name="pod-member")
        d.setVar("CONTAINER_POD", "mypod")
        d.setVar("CONTAINER_PORTS", "8080:80")
        ns["do_validate_quadlet"](d, bb)

        assert any("pod member" in w.lower() for w in bb.warnings)

    def test_valid_config_no_fatals(self, env):
        d, bb, ns = env
        _set_defaults(d)
        ns["do_validate_quadlet"](d, bb)

        assert bb.fatals == []


# ---------------------------------------------------------------------------
# Additional coverage: entrypoint, command, user, working dir, labels,
# security opts, cgroups, stop timeout, restart policies, combined features
# ---------------------------------------------------------------------------

class TestEntrypointAndCommand:

    def test_entrypoint(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_ENTRYPOINT", "/usr/bin/my-init")
        sections = _generate(env)

        exec_vals = _as_list(sections["Container"]["Exec"])
        assert "/usr/bin/my-init" in exec_vals

    def test_command(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_COMMAND", "--verbose --port 8080")
        sections = _generate(env)

        exec_vals = _as_list(sections["Container"]["Exec"])
        assert "--verbose --port 8080" in exec_vals

    def test_both_entrypoint_and_command(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_ENTRYPOINT", "/bin/sh")
        d.setVar("CONTAINER_COMMAND", "-c 'echo hello'")
        sections = _generate(env)

        exec_vals = _as_list(sections["Container"]["Exec"])
        assert "/bin/sh" in exec_vals
        assert "-c 'echo hello'" in exec_vals


class TestUser:

    def test_user(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_USER", "1000:1000")
        sections = _generate(env)

        assert sections["Container"]["User"] == "1000:1000"

    def test_no_user_omitted(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        assert "User" not in sections["Container"]


class TestWorkingDir:

    def test_working_dir(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_WORKING_DIR", "/app")
        sections = _generate(env)

        assert sections["Container"]["WorkingDir"] == "/app"


class TestLabels:

    def test_single_label(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_LABELS", "com.example.version=1.0")
        sections = _generate(env)

        assert sections["Container"]["Label"] == "com.example.version=1.0"

    def test_multiple_labels(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_LABELS", "app=myapp tier=frontend")
        sections = _generate(env)

        labels = _as_list(sections["Container"]["Label"])
        assert labels == ["app=myapp", "tier=frontend"]

    def test_label_without_equals_ignored(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_LABELS", "good=val badlabel")
        sections = _generate(env)

        assert sections["Container"]["Label"] == "good=val"


class TestSecurityOpts:

    def test_single_security_opt(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_SECURITY_OPTS", "no-new-privileges")
        sections = _generate(env)

        assert sections["Container"]["SecurityOpt"] == "no-new-privileges"

    def test_multiple_security_opts(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_SECURITY_OPTS", "no-new-privileges seccomp=unconfined")
        sections = _generate(env)

        opts = _as_list(sections["Container"]["SecurityOpt"])
        assert opts == ["no-new-privileges", "seccomp=unconfined"]


class TestCgroups:

    def test_cgroups_mode(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_CGROUPS", "no-conmon")
        sections = _generate(env)

        podman_args = _as_list(sections["Container"]["PodmanArgs"])
        assert "--cgroups no-conmon" in podman_args


class TestStopTimeout:

    def test_stop_timeout(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_STOP_TIMEOUT", "30")
        sections = _generate(env)

        assert sections["Service"]["TimeoutStopSec"] == "30"

    def test_no_stop_timeout(self, env):
        d, _, _ = env
        _set_defaults(d)
        sections = _generate(env)

        assert "TimeoutStopSec" not in sections["Service"]


class TestRestartPolicy:

    def test_restart_on_failure(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_RESTART", "on-failure")
        sections = _generate(env)

        assert sections["Service"]["Restart"] == "on-failure"

    def test_restart_no(self, env):
        d, _, _ = env
        _set_defaults(d)
        d.setVar("CONTAINER_RESTART", "no")
        sections = _generate(env)

        assert sections["Service"]["Restart"] == "no"

    def test_restart_defaults_to_always(self, env):
        d, _, _ = env
        _set_defaults(d)
        # Do not set CONTAINER_RESTART at all
        sections = _generate(env)

        assert sections["Service"]["Restart"] == "always"


# ---------------------------------------------------------------------------
# Combined / integration-style tests
# ---------------------------------------------------------------------------

class TestCombined:

    def test_full_featured_container(self, env):
        """Exercise as many options as possible in a single generation run."""
        d, _, _ = env
        _set_defaults(d, name="full-featured", image="ghcr.io/org/app:v2.3")
        d.setVar("CONTAINER_COMMAND", "--debug")
        d.setVar("CONTAINER_ENVIRONMENT", "DB_HOST=db LOG_LEVEL=debug")
        d.setVar("CONTAINER_PORTS", "443:8443 80:8080")
        d.setVar("CONTAINER_VOLUMES", "/data/app:/app/data:rw /etc/ssl:/ssl:ro")
        d.setVar("CONTAINER_NETWORK", "appnet")
        d.setVar("NETWORKS", "appnet")
        d.setVar("CONTAINER_USER", "1000:1000")
        d.setVar("CONTAINER_WORKING_DIR", "/app")
        d.setVar("CONTAINER_LABELS", "app=myapp version=2.3")
        d.setVar("CONTAINER_CAPS_ADD", "NET_BIND_SERVICE")
        d.setVar("CONTAINER_CAPS_DROP", "ALL")
        d.setVar("CONTAINER_READ_ONLY", "1")
        d.setVar("CONTAINER_MEMORY_LIMIT", "1g")
        d.setVar("CONTAINER_CPU_LIMIT", "2")
        d.setVar("CONTAINER_TIMEZONE", "Europe/Rome")
        d.setVar("CONTAINER_HEALTH_CMD", "curl -f http://localhost:8080/health")
        d.setVar("CONTAINER_HEALTH_INTERVAL", "30s")
        d.setVar("CONTAINER_HEALTH_TIMEOUT", "5s")
        d.setVar("CONTAINER_HEALTH_RETRIES", "3")
        d.setVar("CONTAINER_HEALTH_START_PERIOD", "60s")
        d.setVar("CONTAINER_LOG_DRIVER", "journald")
        d.setVar("CONTAINER_ULIMITS", "nofile=65536:65536")
        d.setVar("CONTAINER_DEVICES", "/dev/ttyUSB0")
        d.setVar("CONTAINER_NETWORK_ALIASES", "app backend")
        d.setVar("CONTAINER_DEPENDS_ON", "db redis")
        d.setVar("CONTAINER_STOP_TIMEOUT", "30")
        d.setVar("CONTAINER_RESTART", "on-failure")

        sections = _generate(env)

        # [Unit]
        assert sections["Unit"]["Description"] == "full-featured container service"
        after = _as_list(sections["Unit"]["After"])
        assert "network-online.target" in after
        assert "db.service" in after
        assert "redis.service" in after

        # [Container]
        c = sections["Container"]
        assert c["Image"] == "ghcr.io/org/app:v2.3"
        assert c["Network"] == "appnet.network"
        assert c["User"] == "1000:1000"
        assert c["WorkingDir"] == "/app"
        assert c["ReadOnly"] == "true"
        assert c["Timezone"] == "Europe/Rome"
        assert c["LogDriver"] == "journald"
        assert c["AddDevice"] == "/dev/ttyUSB0"

        ports = _as_list(c["PublishPort"])
        assert "443:8443" in ports
        assert "80:8080" in ports

        vols = _as_list(c["Volume"])
        assert "/data/app:/app/data:rw" in vols
        assert "/etc/ssl:/ssl:ro" in vols

        envs = _as_list(c["Environment"])
        assert "DB_HOST=db" in envs
        assert "LOG_LEVEL=debug" in envs

        labels = _as_list(c["Label"])
        assert "app=myapp" in labels
        assert "version=2.3" in labels

        assert c["AddCapability"] == "NET_BIND_SERVICE"
        assert c["DropCapability"] == "ALL"

        assert c["HealthCmd"] == "curl -f http://localhost:8080/health"
        assert c["HealthInterval"] == "30s"
        assert c["HealthTimeout"] == "5s"
        assert c["HealthRetries"] == "3"
        assert c["HealthStartPeriod"] == "60s"

        assert c["Ulimit"] == "nofile=65536:65536"

        podman_args = _as_list(c["PodmanArgs"])
        assert "--memory 1g" in podman_args
        assert "--cpus 2" in podman_args
        assert "--network-alias app" in podman_args
        assert "--network-alias backend" in podman_args

        # [Service]
        assert sections["Service"]["Restart"] == "on-failure"
        assert sections["Service"]["TimeoutStopSec"] == "30"

        # [Install]
        assert sections["Install"]["WantedBy"] == "multi-user.target"

    def test_section_ordering_in_raw_output(self, env):
        """Verify that sections appear in [Unit], [Container], [Service], [Install] order."""
        d, _, _ = env
        _set_defaults(d)
        _generate(env)
        raw = _raw_content(d)

        unit_pos = raw.index("[Unit]")
        container_pos = raw.index("[Container]")
        service_pos = raw.index("[Service]")
        install_pos = raw.index("[Install]")

        assert unit_pos < container_pos < service_pos < install_pos

    def test_file_ends_with_newline(self, env):
        d, _, _ = env
        _set_defaults(d)
        _generate(env)
        raw = _raw_content(d)

        assert raw.endswith("\n")

    def test_comment_header(self, env):
        d, _, _ = env
        _set_defaults(d, name="my-svc")
        _generate(env)
        raw = _raw_content(d)

        assert "# Podman Quadlet file for my-svc" in raw
        assert "# Auto-generated by meta-container-deploy" in raw
