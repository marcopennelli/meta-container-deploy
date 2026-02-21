"""
Tests for container-manifest.bbclass.

Verifies manifest parsing, Quadlet file generation for containers, pods,
and networks, including privileged mode, network suffix logic, pod membership,
disabled containers, environment handling, and full integration scenarios.
"""

import json
import os

import pytest

from conftest import BBFatalError, MockBB, MockDataStore, load_bbclass, parse_quadlet


BBCLASS_PATH = os.path.join(
    os.path.dirname(os.path.dirname(__file__)), "classes", "container-manifest.bbclass"
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_manifest(tmp_path, manifest_dict):
    """Write a manifest dict as JSON and return its path."""
    manifest_file = os.path.join(str(tmp_path), "manifest.json")
    with open(manifest_file, "w") as f:
        json.dump(manifest_dict, f)
    return manifest_file


def _setup_datastore(tmp_path, manifest_path):
    """Return a MockDataStore with WORKDIR, CONTAINER_MANIFEST, and TARGET_ARCH set."""
    d = MockDataStore()
    d.setVar("WORKDIR", str(tmp_path))
    d.setVar("CONTAINER_MANIFEST", manifest_path)
    d.setVar("TARGET_ARCH", "x86_64")
    return d


def _load_ns(mock_bb=None):
    """Load the bbclass namespace with a fresh or provided MockBB."""
    if mock_bb is None:
        mock_bb = MockBB()
    return load_bbclass(BBCLASS_PATH, mock_bb), mock_bb


def _read_quadlet(tmp_path, subdir, filename):
    """Read a generated quadlet file and return its parsed sections."""
    path = os.path.join(str(tmp_path), subdir, filename)
    assert os.path.isfile(path), f"Expected quadlet file not found: {path}"
    with open(path) as f:
        content = f.read()
    return parse_quadlet(content)


# ---------------------------------------------------------------------------
# 1. Parse manifest - basic JSON with containers returns correct tuple
# ---------------------------------------------------------------------------

class TestParseManifest:
    """Tests for parse_container_manifest."""

    def test_basic_json_with_containers(self, tmp_path):
        """Parsing a minimal JSON manifest returns (containers, [], [])."""
        ns, _ = _load_ns()
        manifest = {
            "containers": [
                {"name": "app1", "image": "docker.io/app1:latest"},
                {"name": "app2", "image": "docker.io/app2:v1"},
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        containers, pods, networks = ns["parse_container_manifest"](manifest_path, d)

        assert len(containers) == 2
        assert containers[0]["name"] == "app1"
        assert containers[1]["image"] == "docker.io/app2:v1"
        assert pods == []
        assert networks == []

    def test_full_manifest_tuple(self, tmp_path):
        """Parsing a manifest with containers, pods, and networks returns all three."""
        ns, _ = _load_ns()
        manifest = {
            "containers": [{"name": "c1", "image": "img:1"}],
            "pods": [{"name": "p1"}],
            "networks": [{"name": "n1"}],
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        containers, pods, networks = ns["parse_container_manifest"](manifest_path, d)

        assert len(containers) == 1
        assert len(pods) == 1
        assert len(networks) == 1

    def test_empty_containers_key(self, tmp_path):
        """An empty containers list returns ([], [], [])."""
        ns, _ = _load_ns()
        manifest = {"containers": []}
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        containers, pods, networks = ns["parse_container_manifest"](manifest_path, d)

        assert containers == []
        assert pods == []
        assert networks == []

    def test_missing_keys_default_to_empty(self, tmp_path):
        """A manifest with no containers/pods/networks keys returns empty lists."""
        ns, _ = _load_ns()
        manifest = {}
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        containers, pods, networks = ns["parse_container_manifest"](manifest_path, d)

        assert containers == []
        assert pods == []
        assert networks == []

    def test_invalid_json_raises(self, tmp_path):
        """Non-JSON, non-YAML content triggers bb.fatal."""
        mock_bb = MockBB()
        ns, _ = _load_ns(mock_bb)
        manifest_file = os.path.join(str(tmp_path), "bad.json")
        with open(manifest_file, "w") as f:
            f.write("{{{invalid json and not yaml either")
        d = _setup_datastore(tmp_path, manifest_file)

        # Should raise through bb.fatal (yaml may or may not be importable)
        with pytest.raises(Exception):
            ns["parse_container_manifest"](manifest_file, d)


# ---------------------------------------------------------------------------
# 2. Basic container - minimal manifest produces .container file
# ---------------------------------------------------------------------------

class TestBasicContainer:
    """Tests for do_generate_quadlets with a minimal container."""

    def test_minimal_container_quadlet(self, tmp_path):
        """A minimal container produces a valid .container quadlet."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "myapp", "image": "docker.io/myapp:latest"}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "myapp.container")

        # [Unit]
        assert "Unit" in sections
        assert sections["Unit"]["Description"] == "myapp container service"
        assert "After" in sections["Unit"]

        # [Container]
        assert "Container" in sections
        assert sections["Container"]["Image"] == "docker.io/myapp:latest"

        # [Service]
        assert "Service" in sections
        assert sections["Service"]["Restart"] == "always"

        # [Install]
        assert "Install" in sections
        assert sections["Install"]["WantedBy"] == "multi-user.target"

    def test_container_with_ports_and_volumes(self, tmp_path):
        """Ports and volumes are rendered as PublishPort and Volume entries."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "web",
                    "image": "nginx:latest",
                    "ports": ["8080:80", "443:443"],
                    "volumes": ["/data:/app/data:rw", "/config:/etc/nginx:ro"],
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "web.container")
        container = sections["Container"]

        # Ports should be a list of two entries
        ports = container["PublishPort"]
        assert isinstance(ports, list)
        assert "8080:80" in ports
        assert "443:443" in ports

        # Volumes
        vols = container["Volume"]
        assert isinstance(vols, list)
        assert "/data:/app/data:rw" in vols
        assert "/config:/etc/nginx:ro" in vols

    def test_container_restart_policy(self, tmp_path):
        """Custom restart_policy is rendered in [Service]."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "svc",
                    "image": "svc:1",
                    "restart_policy": "on-failure",
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "svc.container")
        assert sections["Service"]["Restart"] == "on-failure"

    def test_container_depends_on(self, tmp_path):
        """depends_on adds After and Requires in [Unit]."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "worker",
                    "image": "worker:1",
                    "depends_on": ["db", "redis"],
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "worker.container")
        unit = sections["Unit"]

        # After should include both the base dependency and the container deps
        after_vals = unit["After"]
        if isinstance(after_vals, str):
            after_vals = [after_vals]
        assert "db.service" in after_vals
        assert "redis.service" in after_vals

        # Requires
        requires_vals = unit["Requires"]
        if isinstance(requires_vals, str):
            requires_vals = [requires_vals]
        assert "db.service" in requires_vals
        assert "redis.service" in requires_vals


# ---------------------------------------------------------------------------
# 3. Privileged mode
# ---------------------------------------------------------------------------

class TestPrivileged:
    """Tests that privileged: true renders SecurityLabelDisable and --privileged."""

    def test_privileged_container(self, tmp_path):
        """privileged: true adds SecurityLabelDisable=true AND PodmanArgs=--privileged."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "priv",
                    "image": "priv:1",
                    "privileged": True,
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "priv.container")
        container = sections["Container"]

        assert container["SecurityLabelDisable"] == "true"
        podman_args = container["PodmanArgs"]
        if isinstance(podman_args, str):
            podman_args = [podman_args]
        assert "--privileged" in podman_args

    def test_non_privileged_container_no_security_disable(self, tmp_path):
        """A non-privileged container does not have SecurityLabelDisable."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "safe", "image": "safe:1"}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "safe.container")
        container = sections["Container"]

        assert "SecurityLabelDisable" not in container
        assert "PodmanArgs" not in container


# ---------------------------------------------------------------------------
# 4. Network with Quadlet-defined network (suffix .network)
# ---------------------------------------------------------------------------

class TestNetworkWithQuadletDefined:
    """When container.network matches a manifest-defined network, use .network suffix."""

    def test_network_suffix_added(self, tmp_path):
        """Network matching a defined network gets .network suffix."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "app", "image": "app:1", "network": "appnet"}
            ],
            "networks": [
                {"name": "appnet", "driver": "bridge"}
            ],
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "app.container")
        assert sections["Container"]["Network"] == "appnet.network"


# ---------------------------------------------------------------------------
# 5. Network without Quadlet-defined network (e.g., "host")
# ---------------------------------------------------------------------------

class TestNetworkWithoutQuadletDefined:
    """When container.network is not manifest-defined, use raw value."""

    def test_host_network_no_suffix(self, tmp_path):
        """network: host renders as Network=host (no .network suffix)."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "hostnet", "image": "app:1", "network": "host"}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "hostnet.container")
        assert sections["Container"]["Network"] == "host"

    def test_bridge_network_without_manifest_definition(self, tmp_path):
        """network: bridge with no manifest network definition gets no suffix."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "bridged", "image": "app:1", "network": "bridge"}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "bridged.container")
        assert sections["Container"]["Network"] == "bridge"


# ---------------------------------------------------------------------------
# 6. Network aliases
# ---------------------------------------------------------------------------

class TestNetworkAliases:
    """Container network_aliases produce PodmanArgs=--network-alias entries."""

    def test_network_aliases_rendered(self, tmp_path):
        """network_aliases produces PodmanArgs=--network-alias for each alias."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "svc",
                    "image": "svc:1",
                    "network_aliases": ["svc-dns", "svc-alt"],
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "svc.container")
        podman_args = sections["Container"]["PodmanArgs"]
        if isinstance(podman_args, str):
            podman_args = [podman_args]

        assert "--network-alias svc-dns" in podman_args
        assert "--network-alias svc-alt" in podman_args


# ---------------------------------------------------------------------------
# 7. Pod membership
# ---------------------------------------------------------------------------

class TestPodMembership:
    """Container with pod field renders Pod=<name>.pod."""

    def test_pod_membership(self, tmp_path):
        """Container with pod: mypod produces Pod=mypod.pod."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "worker", "image": "worker:1", "pod": "mypod"}
            ],
            "pods": [{"name": "mypod"}],
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "worker.container")
        assert sections["Container"]["Pod"] == "mypod.pod"


# ---------------------------------------------------------------------------
# 8. Pod generation
# ---------------------------------------------------------------------------

class TestPodGeneration:
    """Tests for do_generate_pods producing .pod quadlet files."""

    def test_basic_pod(self, tmp_path):
        """A basic pod manifest generates a valid .pod file."""
        ns, mock_bb = _load_ns()
        manifest = {
            "pods": [
                {
                    "name": "mypod",
                    "ports": ["9090:9090", "8080:8080"],
                    "hostname": "mypod-host",
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_pods"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "mypod.pod")

        # [Unit]
        assert sections["Unit"]["Description"] == "mypod pod"

        # [Pod]
        pod_section = sections["Pod"]
        assert pod_section["PodName"] == "mypod"
        assert pod_section["Hostname"] == "mypod-host"

        ports = pod_section["PublishPort"]
        if isinstance(ports, str):
            ports = [ports]
        assert "9090:9090" in ports
        assert "8080:8080" in ports

        # [Install]
        assert sections["Install"]["WantedBy"] == "multi-user.target"

    def test_pod_with_volumes_and_dns(self, tmp_path):
        """Pod volumes and DNS entries are rendered correctly."""
        ns, mock_bb = _load_ns()
        manifest = {
            "pods": [
                {
                    "name": "datapod",
                    "volumes": ["/data:/app/data:rw"],
                    "dns": ["8.8.8.8", "1.1.1.1"],
                    "dns_search": ["example.com"],
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_pods"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "datapod.pod")
        pod_section = sections["Pod"]

        assert pod_section["Volume"] == "/data:/app/data:rw"

        dns_vals = pod_section["DNS"]
        if isinstance(dns_vals, str):
            dns_vals = [dns_vals]
        assert "8.8.8.8" in dns_vals
        assert "1.1.1.1" in dns_vals

        assert pod_section["DNSSearch"] == "example.com"

    def test_disabled_pod_goes_to_available(self, tmp_path):
        """A pod with enabled: false goes to quadlets-available/."""
        ns, mock_bb = _load_ns()
        manifest = {
            "pods": [
                {"name": "offpod", "enabled": False}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_pods"](d, mock_bb)

        # Should be in quadlets-available, not quadlets
        avail_path = os.path.join(str(tmp_path), "quadlets-available", "offpod.pod")
        active_path = os.path.join(str(tmp_path), "quadlets", "offpod.pod")
        assert os.path.isfile(avail_path)
        assert not os.path.exists(active_path)


# ---------------------------------------------------------------------------
# 9. Pod network suffix
# ---------------------------------------------------------------------------

class TestPodNetworkSuffix:
    """Pod network matching manifest network gets .network suffix."""

    def test_pod_network_with_suffix(self, tmp_path):
        """Pod network matching a defined network gets .network suffix."""
        ns, mock_bb = _load_ns()
        manifest = {
            "pods": [
                {"name": "netpod", "network": "mynet"}
            ],
            "networks": [
                {"name": "mynet", "driver": "bridge"}
            ],
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_pods"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "netpod.pod")
        assert sections["Pod"]["Network"] == "mynet.network"

    def test_pod_network_without_suffix(self, tmp_path):
        """Pod network not matching any defined network gets raw value."""
        ns, mock_bb = _load_ns()
        manifest = {
            "pods": [
                {"name": "hostpod", "network": "host"}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_pods"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "hostpod.pod")
        assert sections["Pod"]["Network"] == "host"


# ---------------------------------------------------------------------------
# 10. Network generation
# ---------------------------------------------------------------------------

class TestNetworkGeneration:
    """Tests for do_generate_networks producing .network quadlet files."""

    def test_basic_network(self, tmp_path):
        """A basic network manifest generates a valid .network file."""
        ns, mock_bb = _load_ns()
        manifest = {
            "networks": [
                {
                    "name": "appnet",
                    "driver": "bridge",
                    "subnet": "10.89.0.0/24",
                    "gateway": "10.89.0.1",
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_networks"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "appnet.network")

        # [Unit]
        assert sections["Unit"]["Description"] == "appnet network"

        # [Network]
        net_section = sections["Network"]
        assert net_section["NetworkName"] == "appnet"
        assert net_section["Driver"] == "bridge"
        assert net_section["Subnet"] == "10.89.0.0/24"
        assert net_section["Gateway"] == "10.89.0.1"

        # [Install]
        assert sections["Install"]["WantedBy"] == "multi-user.target"

    def test_network_with_ipv6_and_internal(self, tmp_path):
        """IPv6 and internal flags are rendered correctly."""
        ns, mock_bb = _load_ns()
        manifest = {
            "networks": [
                {
                    "name": "isolated",
                    "ipv6": True,
                    "internal": True,
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_networks"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "isolated.network")
        net_section = sections["Network"]
        assert net_section["IPv6"] == "true"
        assert net_section["Internal"] == "true"

    def test_network_with_labels_and_options(self, tmp_path):
        """Network labels and driver options are rendered."""
        ns, mock_bb = _load_ns()
        manifest = {
            "networks": [
                {
                    "name": "labeled",
                    "labels": {"env": "prod", "team": "infra"},
                    "options": {"mtu": "9000"},
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_networks"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "labeled.network")
        net_section = sections["Network"]

        label_vals = net_section["Label"]
        if isinstance(label_vals, str):
            label_vals = [label_vals]
        assert "env=prod" in label_vals
        assert "team=infra" in label_vals

        assert net_section["Options"] == "mtu=9000"

    def test_disabled_network_goes_to_available(self, tmp_path):
        """A network with enabled: false goes to quadlets-available/."""
        ns, mock_bb = _load_ns()
        manifest = {
            "networks": [
                {"name": "offnet", "enabled": False}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_networks"](d, mock_bb)

        avail_path = os.path.join(str(tmp_path), "quadlets-available", "offnet.network")
        active_path = os.path.join(str(tmp_path), "quadlets", "offnet.network")
        assert os.path.isfile(avail_path)
        assert not os.path.exists(active_path)

    def test_multiple_networks(self, tmp_path):
        """Multiple networks each produce their own .network file."""
        ns, mock_bb = _load_ns()
        manifest = {
            "networks": [
                {"name": "net1", "driver": "bridge"},
                {"name": "net2", "subnet": "172.20.0.0/16"},
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_networks"](d, mock_bb)

        s1 = _read_quadlet(tmp_path, "quadlets", "net1.network")
        s2 = _read_quadlet(tmp_path, "quadlets", "net2.network")

        assert s1["Network"]["NetworkName"] == "net1"
        assert s1["Network"]["Driver"] == "bridge"
        assert s2["Network"]["NetworkName"] == "net2"
        assert s2["Network"]["Subnet"] == "172.20.0.0/16"


# ---------------------------------------------------------------------------
# 11. Disabled container
# ---------------------------------------------------------------------------

class TestDisabledContainer:
    """Tests that enabled: false places quadlet in quadlets-available/."""

    def test_disabled_container_in_available_dir(self, tmp_path):
        """A disabled container goes to quadlets-available/, not quadlets/."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "offline", "image": "offline:1", "enabled": False}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        avail_path = os.path.join(str(tmp_path), "quadlets-available", "offline.container")
        active_path = os.path.join(str(tmp_path), "quadlets", "offline.container")
        assert os.path.isfile(avail_path)
        assert not os.path.exists(active_path)

        # The file should still be a valid quadlet with [Install] section
        sections = _read_quadlet(tmp_path, "quadlets-available", "offline.container")
        assert sections["Install"]["WantedBy"] == "multi-user.target"

    def test_enabled_true_container_in_active_dir(self, tmp_path):
        """An explicitly enabled container goes to quadlets/."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "online", "image": "online:1", "enabled": True}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        active_path = os.path.join(str(tmp_path), "quadlets", "online.container")
        avail_path = os.path.join(str(tmp_path), "quadlets-available", "online.container")
        assert os.path.isfile(active_path)
        assert not os.path.exists(avail_path)

    def test_default_enabled_container_in_active_dir(self, tmp_path):
        """A container without enabled key defaults to active directory."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "default", "image": "default:1"}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        active_path = os.path.join(str(tmp_path), "quadlets", "default.container")
        assert os.path.isfile(active_path)


# ---------------------------------------------------------------------------
# 12. Environment as dict
# ---------------------------------------------------------------------------

class TestEnvironmentDict:
    """Tests that environment dict produces Environment=KEY=val lines."""

    def test_environment_dict(self, tmp_path):
        """Environment dict entries become Environment=KEY=val lines."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "envapp",
                    "image": "envapp:1",
                    "environment": {"DB_HOST": "localhost", "DB_PORT": "5432"},
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "envapp.container")
        env_vals = sections["Container"]["Environment"]
        if isinstance(env_vals, str):
            env_vals = [env_vals]

        assert "DB_HOST=localhost" in env_vals
        assert "DB_PORT=5432" in env_vals

    def test_environment_list(self, tmp_path):
        """Environment as a list of KEY=val strings is also handled."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "envlist",
                    "image": "envlist:1",
                    "environment": ["FOO=bar", "BAZ=qux"],
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "envlist.container")
        env_vals = sections["Container"]["Environment"]
        if isinstance(env_vals, str):
            env_vals = [env_vals]

        assert "FOO=bar" in env_vals
        assert "BAZ=qux" in env_vals


# ---------------------------------------------------------------------------
# 13. Full integration
# ---------------------------------------------------------------------------

class TestFullIntegration:
    """Full integration: manifest with networks + containers + pods all
    referencing each other produces correct files with proper cross-references."""

    def _build_full_manifest(self):
        return {
            "networks": [
                {
                    "name": "appnet",
                    "driver": "bridge",
                    "subnet": "10.89.0.0/24",
                    "gateway": "10.89.0.1",
                }
            ],
            "pods": [
                {
                    "name": "backend",
                    "ports": ["5000:5000"],
                    "network": "appnet",
                }
            ],
            "containers": [
                {
                    "name": "api",
                    "image": "docker.io/myapi:v2",
                    "pod": "backend",
                    "environment": {"API_KEY": "secret123"},
                    "network_aliases": ["api-dns"],
                },
                {
                    "name": "db",
                    "image": "postgres:15",
                    "network": "appnet",
                    "ports": ["5432:5432"],
                    "volumes": ["/data/pg:/var/lib/postgresql/data:rw"],
                    "environment": {"POSTGRES_PASSWORD": "pass"},
                    "privileged": True,
                },
                {
                    "name": "monitoring",
                    "image": "prom/prometheus:latest",
                    "network": "host",
                    "enabled": False,
                    "depends_on": ["api"],
                },
            ],
        }

    def test_integration_network_file(self, tmp_path):
        """Network is generated correctly in the integration scenario."""
        ns, mock_bb = _load_ns()
        manifest = self._build_full_manifest()
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_networks"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "appnet.network")
        assert sections["Network"]["NetworkName"] == "appnet"
        assert sections["Network"]["Driver"] == "bridge"
        assert sections["Network"]["Subnet"] == "10.89.0.0/24"
        assert sections["Network"]["Gateway"] == "10.89.0.1"

    def test_integration_pod_file(self, tmp_path):
        """Pod references appnet network with .network suffix."""
        ns, mock_bb = _load_ns()
        manifest = self._build_full_manifest()
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_pods"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "backend.pod")
        assert sections["Pod"]["PodName"] == "backend"
        assert sections["Pod"]["PublishPort"] == "5000:5000"
        assert sections["Pod"]["Network"] == "appnet.network"

    def test_integration_container_with_pod(self, tmp_path):
        """Container 'api' joins pod 'backend' and has network aliases."""
        ns, mock_bb = _load_ns()
        manifest = self._build_full_manifest()
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "api.container")
        container = sections["Container"]
        assert container["Pod"] == "backend.pod"
        assert container["Image"] == "docker.io/myapi:v2"
        assert container["Environment"] == "API_KEY=secret123"

        podman_args = container["PodmanArgs"]
        if isinstance(podman_args, str):
            podman_args = [podman_args]
        assert "--network-alias api-dns" in podman_args

    def test_integration_privileged_db_with_network(self, tmp_path):
        """Container 'db' is privileged and uses appnet with .network suffix."""
        ns, mock_bb = _load_ns()
        manifest = self._build_full_manifest()
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "db.container")
        container = sections["Container"]

        assert container["Image"] == "postgres:15"
        assert container["Network"] == "appnet.network"
        assert container["SecurityLabelDisable"] == "true"
        assert container["Volume"] == "/data/pg:/var/lib/postgresql/data:rw"
        assert container["PublishPort"] == "5432:5432"

        podman_args = container["PodmanArgs"]
        if isinstance(podman_args, str):
            podman_args = [podman_args]
        assert "--privileged" in podman_args

    def test_integration_disabled_monitoring(self, tmp_path):
        """Container 'monitoring' with enabled: false goes to quadlets-available."""
        ns, mock_bb = _load_ns()
        manifest = self._build_full_manifest()
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        avail_path = os.path.join(
            str(tmp_path), "quadlets-available", "monitoring.container"
        )
        active_path = os.path.join(
            str(tmp_path), "quadlets", "monitoring.container"
        )
        assert os.path.isfile(avail_path)
        assert not os.path.exists(active_path)

        sections = _read_quadlet(tmp_path, "quadlets-available", "monitoring.container")
        assert sections["Container"]["Network"] == "host"
        assert sections["Container"]["Image"] == "prom/prometheus:latest"

        # Should depend on api
        after_vals = sections["Unit"]["After"]
        if isinstance(after_vals, str):
            after_vals = [after_vals]
        assert "api.service" in after_vals

    def test_integration_all_generators(self, tmp_path):
        """Running all three generators produces expected file counts."""
        ns, mock_bb = _load_ns()
        manifest = self._build_full_manifest()
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_networks"](d, mock_bb)
        ns["do_generate_pods"](d, mock_bb)
        ns["do_generate_quadlets"](d, mock_bb)

        quadlets_dir = os.path.join(str(tmp_path), "quadlets")
        avail_dir = os.path.join(str(tmp_path), "quadlets-available")

        # Active: appnet.network, backend.pod, api.container, db.container
        active_files = os.listdir(quadlets_dir)
        assert "appnet.network" in active_files
        assert "backend.pod" in active_files
        assert "api.container" in active_files
        assert "db.container" in active_files
        assert "monitoring.container" not in active_files

        # Available: monitoring.container
        avail_files = os.listdir(avail_dir)
        assert "monitoring.container" in avail_files


# ---------------------------------------------------------------------------
# Helper function tests
# ---------------------------------------------------------------------------

class TestHelperFunctions:
    """Tests for helper/utility functions in the bbclass."""

    def test_get_oci_arch_x86_64(self, tmp_path):
        """x86_64 maps to amd64."""
        ns, _ = _load_ns()
        d = MockDataStore()
        d.setVar("TARGET_ARCH", "x86_64")
        assert ns["get_oci_arch"](d) == "amd64"

    def test_get_oci_arch_aarch64(self, tmp_path):
        """aarch64 maps to arm64."""
        ns, _ = _load_ns()
        d = MockDataStore()
        d.setVar("TARGET_ARCH", "aarch64")
        assert ns["get_oci_arch"](d) == "arm64"

    def test_get_oci_arch_unknown_passthrough(self, tmp_path):
        """Unknown arch passes through unchanged."""
        ns, _ = _load_ns()
        d = MockDataStore()
        d.setVar("TARGET_ARCH", "sparc")
        assert ns["get_oci_arch"](d) == "sparc"

    def test_get_network_list_from_manifest(self, tmp_path):
        """get_network_list_from_manifest returns list of network names."""
        ns, _ = _load_ns()
        manifest = {
            "networks": [
                {"name": "net1"},
                {"name": "net2"},
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        names = ns["get_network_list_from_manifest"](d)
        assert names == ["net1", "net2"]

    def test_get_network_list_no_manifest(self):
        """get_network_list_from_manifest returns [] when no manifest set."""
        ns, _ = _load_ns()
        d = MockDataStore()
        assert ns["get_network_list_from_manifest"](d) == []

    def test_get_container_list_from_manifest(self, tmp_path):
        """get_container_list_from_manifest returns container names."""
        ns, _ = _load_ns()
        manifest = {
            "containers": [
                {"name": "c1", "image": "img1"},
                {"name": "c2", "image": "img2"},
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        names = ns["get_container_list_from_manifest"](d)
        assert names == ["c1", "c2"]

    def test_get_pod_list_from_manifest(self, tmp_path):
        """get_pod_list_from_manifest returns pod names."""
        ns, _ = _load_ns()
        manifest = {
            "pods": [
                {"name": "p1"},
                {"name": "p2"},
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        names = ns["get_pod_list_from_manifest"](d)
        assert names == ["p1", "p2"]

    def test_get_container_from_manifest(self, tmp_path):
        """get_container_from_manifest returns the correct container dict."""
        ns, _ = _load_ns()
        containers = [
            {"name": "a", "image": "img_a"},
            {"name": "b", "image": "img_b"},
        ]
        result = ns["get_container_from_manifest"](containers, "b")
        assert result["image"] == "img_b"

    def test_get_container_from_manifest_missing(self, tmp_path):
        """get_container_from_manifest returns {} for unknown name."""
        ns, _ = _load_ns()
        containers = [{"name": "a", "image": "img_a"}]
        result = ns["get_container_from_manifest"](containers, "missing")
        assert result == {}


# ---------------------------------------------------------------------------
# Additional container options
# ---------------------------------------------------------------------------

class TestContainerAdvancedOptions:
    """Tests for advanced container options like health checks, log driver, etc."""

    def test_health_check_options(self, tmp_path):
        """Health check options are rendered in the container quadlet."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "healthapp",
                    "image": "healthapp:1",
                    "health_cmd": "curl -f http://localhost/health",
                    "health_interval": "30s",
                    "health_timeout": "10s",
                    "health_retries": 3,
                    "health_start_period": "60s",
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "healthapp.container")
        container = sections["Container"]
        assert container["HealthCmd"] == "curl -f http://localhost/health"
        assert container["HealthInterval"] == "30s"
        assert container["HealthTimeout"] == "10s"
        assert container["HealthRetries"] == "3"
        assert container["HealthStartPeriod"] == "60s"

    def test_log_driver_and_options(self, tmp_path):
        """Log driver and log options are rendered correctly."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "logapp",
                    "image": "logapp:1",
                    "log_driver": "journald",
                    "log_opt": {"tag": "myapp", "max-size": "10m"},
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "logapp.container")
        container = sections["Container"]
        assert container["LogDriver"] == "journald"

        podman_args = container["PodmanArgs"]
        if isinstance(podman_args, str):
            podman_args = [podman_args]
        assert any("--log-opt tag=myapp" in a for a in podman_args)
        assert any("--log-opt max-size=10m" in a for a in podman_args)

    def test_ulimits(self, tmp_path):
        """Ulimits are rendered as Ulimit= entries."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "ulimitapp",
                    "image": "ulimitapp:1",
                    "ulimits": {"nofile": "65536:65536"},
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "ulimitapp.container")
        assert sections["Container"]["Ulimit"] == "nofile=65536:65536"

    def test_capabilities(self, tmp_path):
        """Capabilities add/drop are rendered correctly."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "capapp",
                    "image": "capapp:1",
                    "capabilities_add": ["NET_ADMIN", "SYS_TIME"],
                    "capabilities_drop": ["ALL"],
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "capapp.container")
        container = sections["Container"]

        add_caps = container["AddCapability"]
        if isinstance(add_caps, str):
            add_caps = [add_caps]
        assert "NET_ADMIN" in add_caps
        assert "SYS_TIME" in add_caps

        assert container["DropCapability"] == "ALL"

    def test_read_only_root_filesystem(self, tmp_path):
        """read_only: true adds ReadOnly=true."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "roapp", "image": "roapp:1", "read_only": True}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "roapp.container")
        assert sections["Container"]["ReadOnly"] == "true"

    def test_timezone(self, tmp_path):
        """timezone field is rendered as Timezone= entry."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "tzapp", "image": "tzapp:1", "timezone": "Europe/Rome"}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "tzapp.container")
        assert sections["Container"]["Timezone"] == "Europe/Rome"

    def test_resource_limits(self, tmp_path):
        """Memory and CPU limits are rendered as PodmanArgs."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "limited",
                    "image": "limited:1",
                    "memory_limit": "512m",
                    "cpu_limit": "1.5",
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "limited.container")
        podman_args = sections["Container"]["PodmanArgs"]
        if isinstance(podman_args, str):
            podman_args = [podman_args]
        assert "--memory 512m" in podman_args
        assert "--cpus 1.5" in podman_args

    def test_user_and_working_dir(self, tmp_path):
        """User and WorkingDir are rendered in the container section."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "userapp",
                    "image": "userapp:1",
                    "user": "1000:1000",
                    "working_dir": "/app",
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "userapp.container")
        assert sections["Container"]["User"] == "1000:1000"
        assert sections["Container"]["WorkingDir"] == "/app"

    def test_devices(self, tmp_path):
        """Device passthrough renders AddDevice= entries."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "devapp",
                    "image": "devapp:1",
                    "devices": ["/dev/video0", "/dev/dri/renderD128"],
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "devapp.container")
        devices = sections["Container"]["AddDevice"]
        if isinstance(devices, str):
            devices = [devices]
        assert "/dev/video0" in devices
        assert "/dev/dri/renderD128" in devices

    def test_labels_dict(self, tmp_path):
        """Container labels as dict are rendered as Label= entries."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {
                    "name": "labelapp",
                    "image": "labelapp:1",
                    "labels": {"app": "myapp", "version": "1.0"},
                }
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "labelapp.container")
        labels = sections["Container"]["Label"]
        if isinstance(labels, str):
            labels = [labels]
        assert "app=myapp" in labels
        assert "version=1.0" in labels

    def test_stop_timeout(self, tmp_path):
        """stop_timeout is rendered as TimeoutStopSec in [Service]."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "slowstop", "image": "slowstop:1", "stop_timeout": 30}
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        sections = _read_quadlet(tmp_path, "quadlets", "slowstop.container")
        assert sections["Service"]["TimeoutStopSec"] == "30"


# ---------------------------------------------------------------------------
# Edge cases & no-manifest scenarios
# ---------------------------------------------------------------------------

class TestEdgeCases:
    """Tests for edge cases and no-op scenarios."""

    def test_no_manifest_set_quadlets_noop(self, tmp_path):
        """do_generate_quadlets with no CONTAINER_MANIFEST is a no-op."""
        ns, mock_bb = _load_ns()
        d = MockDataStore()
        d.setVar("WORKDIR", str(tmp_path))
        d.setVar("TARGET_ARCH", "x86_64")
        # No CONTAINER_MANIFEST set

        ns["do_generate_quadlets"](d, mock_bb)

        quadlets_dir = os.path.join(str(tmp_path), "quadlets")
        assert not os.path.exists(quadlets_dir)

    def test_no_manifest_set_pods_noop(self, tmp_path):
        """do_generate_pods with no CONTAINER_MANIFEST is a no-op."""
        ns, mock_bb = _load_ns()
        d = MockDataStore()
        d.setVar("WORKDIR", str(tmp_path))
        d.setVar("TARGET_ARCH", "x86_64")

        ns["do_generate_pods"](d, mock_bb)

        quadlets_dir = os.path.join(str(tmp_path), "quadlets")
        assert not os.path.exists(quadlets_dir)

    def test_no_manifest_set_networks_noop(self, tmp_path):
        """do_generate_networks with no CONTAINER_MANIFEST is a no-op."""
        ns, mock_bb = _load_ns()
        d = MockDataStore()
        d.setVar("WORKDIR", str(tmp_path))
        d.setVar("TARGET_ARCH", "x86_64")

        ns["do_generate_networks"](d, mock_bb)

        quadlets_dir = os.path.join(str(tmp_path), "quadlets")
        assert not os.path.exists(quadlets_dir)

    def test_empty_containers_list_noop(self, tmp_path):
        """Manifest with empty containers list produces no files."""
        ns, mock_bb = _load_ns()
        manifest = {"containers": []}
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        quadlets_dir = os.path.join(str(tmp_path), "quadlets")
        assert not os.path.exists(quadlets_dir)

    def test_multiple_containers_each_get_file(self, tmp_path):
        """Multiple containers each produce their own .container file."""
        ns, mock_bb = _load_ns()
        manifest = {
            "containers": [
                {"name": "svc1", "image": "svc1:1"},
                {"name": "svc2", "image": "svc2:2"},
                {"name": "svc3", "image": "svc3:3"},
            ]
        }
        manifest_path = _write_manifest(tmp_path, manifest)
        d = _setup_datastore(tmp_path, manifest_path)

        ns["do_generate_quadlets"](d, mock_bb)

        quadlets_dir = os.path.join(str(tmp_path), "quadlets")
        files = os.listdir(quadlets_dir)
        assert "svc1.container" in files
        assert "svc2.container" in files
        assert "svc3.container" in files
