"""
Tests for container-localconf.bbclass.

Covers:
  - Helper functions: get_container_var, get_container_list, get_pod_var,
    get_pod_list, get_network_var, get_network_list
  - Container Quadlet generation (do_generate_quadlets)
  - Pod Quadlet generation (do_generate_pods)
  - Network Quadlet generation (do_generate_networks)
  - Integration scenarios combining networks, pods, and containers
"""

import os
import pytest

from conftest import MockDataStore, MockBB, load_bbclass, parse_quadlet


BBCLASS_PATH = os.path.join(
    os.path.dirname(os.path.dirname(__file__)), 'classes', 'container-localconf.bbclass'
)


@pytest.fixture
def ns():
    """Load the bbclass into a namespace with a fresh MockBB."""
    mock_bb = MockBB()
    return load_bbclass(BBCLASS_PATH, mock_bb)


@pytest.fixture
def bb_mod():
    """Provide a fresh MockBB instance (standalone)."""
    return MockBB()


@pytest.fixture
def d():
    """Provide a fresh MockDataStore instance."""
    return MockDataStore()


# ---------------------------------------------------------------------------
# Helper to run a BitBake-style Python task.  The conftest wraps tasks as
#   def task_name(d, bb): ...
# so we call them with (d, bb).  The helpers (get_container_var, etc.) are
# plain functions that only take (d, ...) and live directly in the namespace.
# ---------------------------------------------------------------------------

def _run_task(ns, task_name, d, bb_mod):
    """Execute a BitBake task function extracted from the bbclass."""
    ns[task_name](d, bb_mod)


# ===========================================================================
#  Helper function tests
# ===========================================================================

class TestGetContainerVar:
    """Tests for get_container_var()."""

    def test_basic_lookup(self, ns, d):
        """Variable is found using the sanitized container name."""
        d.setVar('CONTAINER_myapp_IMAGE', 'docker.io/myapp:latest')
        result = ns['get_container_var'](d, 'myapp', 'IMAGE')
        assert result == 'docker.io/myapp:latest'

    def test_fallback_to_default(self, ns, d):
        """Returns the default when the variable is not set."""
        result = ns['get_container_var'](d, 'myapp', 'IMAGE', 'fallback')
        assert result == 'fallback'

    def test_default_is_empty_string(self, ns, d):
        """Default is empty string when not specified."""
        result = ns['get_container_var'](d, 'myapp', 'IMAGE')
        assert result == ''

    def test_dash_to_underscore(self, ns, d):
        """Dashes in container name are converted to underscores for lookup."""
        d.setVar('CONTAINER_mqtt_broker_IMAGE', 'eclipse-mosquitto:2.0')
        result = ns['get_container_var'](d, 'mqtt-broker', 'IMAGE')
        assert result == 'eclipse-mosquitto:2.0'

    def test_dot_to_underscore(self, ns, d):
        """Dots in container name are converted to underscores for lookup."""
        d.setVar('CONTAINER_my_app_v2_IMAGE', 'myregistry/app:v2')
        result = ns['get_container_var'](d, 'my-app.v2', 'IMAGE')
        assert result == 'myregistry/app:v2'

    def test_original_name_fallback(self, ns, d):
        """Falls back to the original (unsanitized) name if sanitized not found."""
        # Contrived: set the variable with the original name format
        d.setVar('CONTAINER_myapp_PORTS', '8080:80')
        result = ns['get_container_var'](d, 'myapp', 'PORTS')
        assert result == '8080:80'

    def test_multiple_vars_same_container(self, ns, d):
        """Different variables for the same container are independently resolved."""
        d.setVar('CONTAINER_web_IMAGE', 'nginx:alpine')
        d.setVar('CONTAINER_web_PORTS', '80:80 443:443')
        d.setVar('CONTAINER_web_RESTART', 'always')
        assert ns['get_container_var'](d, 'web', 'IMAGE') == 'nginx:alpine'
        assert ns['get_container_var'](d, 'web', 'PORTS') == '80:80 443:443'
        assert ns['get_container_var'](d, 'web', 'RESTART') == 'always'


class TestGetContainerList:
    """Tests for get_container_list()."""

    def test_splits_correctly(self, ns, d):
        """Space-separated container names are split into a list."""
        d.setVar('CONTAINERS', 'mqtt-broker nginx-proxy redis')
        result = ns['get_container_list'](d)
        assert result == ['mqtt-broker', 'nginx-proxy', 'redis']

    def test_empty_string(self, ns, d):
        """Empty CONTAINERS yields an empty list."""
        d.setVar('CONTAINERS', '')
        result = ns['get_container_list'](d)
        assert result == []

    def test_not_set(self, ns, d):
        """Missing CONTAINERS variable yields an empty list."""
        result = ns['get_container_list'](d)
        assert result == []

    def test_extra_whitespace(self, ns, d):
        """Extra whitespace is handled gracefully."""
        d.setVar('CONTAINERS', '  app1   app2  ')
        result = ns['get_container_list'](d)
        assert result == ['app1', 'app2']

    def test_single_container(self, ns, d):
        """A single container name returns a single-element list."""
        d.setVar('CONTAINERS', 'only-one')
        result = ns['get_container_list'](d)
        assert result == ['only-one']


class TestGetPodVar:
    """Tests for get_pod_var()."""

    def test_basic_lookup(self, ns, d):
        d.setVar('POD_myapp_PORTS', '8080:8080')
        result = ns['get_pod_var'](d, 'myapp', 'PORTS')
        assert result == '8080:8080'

    def test_fallback_to_default(self, ns, d):
        result = ns['get_pod_var'](d, 'myapp', 'PORTS', 'none')
        assert result == 'none'

    def test_dash_to_underscore(self, ns, d):
        d.setVar('POD_my_pod_NETWORK', 'bridge')
        result = ns['get_pod_var'](d, 'my-pod', 'NETWORK')
        assert result == 'bridge'

    def test_dot_to_underscore(self, ns, d):
        d.setVar('POD_my_pod_v2_HOSTNAME', 'mypod')
        result = ns['get_pod_var'](d, 'my-pod.v2', 'HOSTNAME')
        assert result == 'mypod'


class TestGetPodList:
    """Tests for get_pod_list()."""

    def test_splits_correctly(self, ns, d):
        d.setVar('PODS', 'infra-pod app-pod')
        result = ns['get_pod_list'](d)
        assert result == ['infra-pod', 'app-pod']

    def test_empty(self, ns, d):
        d.setVar('PODS', '')
        assert ns['get_pod_list'](d) == []

    def test_not_set(self, ns, d):
        assert ns['get_pod_list'](d) == []


class TestGetNetworkVar:
    """Tests for get_network_var()."""

    def test_basic_lookup(self, ns, d):
        d.setVar('NETWORK_appnet_DRIVER', 'bridge')
        result = ns['get_network_var'](d, 'appnet', 'DRIVER')
        assert result == 'bridge'

    def test_fallback_to_default(self, ns, d):
        result = ns['get_network_var'](d, 'appnet', 'DRIVER', 'bridge')
        assert result == 'bridge'

    def test_dash_to_underscore(self, ns, d):
        d.setVar('NETWORK_my_net_SUBNET', '10.0.0.0/24')
        result = ns['get_network_var'](d, 'my-net', 'SUBNET')
        assert result == '10.0.0.0/24'


class TestGetNetworkList:
    """Tests for get_network_list()."""

    def test_splits_correctly(self, ns, d):
        d.setVar('NETWORKS', 'frontend-net backend-net')
        result = ns['get_network_list'](d)
        assert result == ['frontend-net', 'backend-net']

    def test_empty(self, ns, d):
        d.setVar('NETWORKS', '')
        assert ns['get_network_list'](d) == []

    def test_not_set(self, ns, d):
        assert ns['get_network_list'](d) == []


# ===========================================================================
#  Container Quadlet generation tests (do_generate_quadlets)
# ===========================================================================

class TestGenerateQuadlets:
    """Tests for do_generate_quadlets task."""

    def _setup_container(self, d, tmp_path, name, image, **extras):
        """Set up a single container in the datastore."""
        safe = name.replace('-', '_').replace('.', '_')
        d.setVar('WORKDIR', str(tmp_path))
        d.setVar('CONTAINERS', name)
        d.setVar(f'CONTAINER_{safe}_IMAGE', image)
        for var, val in extras.items():
            d.setVar(f'CONTAINER_{safe}_{var}', val)

    def _read_quadlet(self, tmp_path, name, available=False):
        """Read and parse a generated .container quadlet file."""
        subdir = 'quadlets-available' if available else 'quadlets'
        path = tmp_path / subdir / f'{name}.container'
        assert path.exists(), f"Expected quadlet file not found: {path}"
        content = path.read_text()
        return parse_quadlet(content), content

    # -- Test 7: Basic container with IMAGE --

    def test_basic_container(self, ns, bb_mod, d, tmp_path):
        """A container with only IMAGE generates a valid .container file."""
        self._setup_container(d, tmp_path, 'myapp', 'docker.io/myapp:latest')

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'myapp')

        assert 'Unit' in sections
        assert sections['Unit']['Description'] == 'myapp container service'

        assert 'Container' in sections
        assert sections['Container']['Image'] == 'docker.io/myapp:latest'

        assert 'Service' in sections
        assert sections['Service']['Restart'] == 'always'

        assert 'Install' in sections
        assert sections['Install']['WantedBy'] == 'multi-user.target'

    # -- Test 8: Multiple containers --

    def test_multiple_containers(self, ns, bb_mod, d, tmp_path):
        """Multiple containers each get their own .container file."""
        d.setVar('WORKDIR', str(tmp_path))
        d.setVar('CONTAINERS', 'app-one app-two')
        d.setVar('CONTAINER_app_one_IMAGE', 'img1:v1')
        d.setVar('CONTAINER_app_two_IMAGE', 'img2:v2')

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        s1, _ = self._read_quadlet(tmp_path, 'app-one')
        s2, _ = self._read_quadlet(tmp_path, 'app-two')

        assert s1['Container']['Image'] == 'img1:v1'
        assert s2['Container']['Image'] == 'img2:v2'

    # -- Test 9: Privileged mode --

    def test_privileged_mode(self, ns, bb_mod, d, tmp_path):
        """Privileged container has SecurityLabelDisable=true and PodmanArgs=--privileged."""
        self._setup_container(d, tmp_path, 'priv', 'img:latest', PRIVILEGED='1')

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, content = self._read_quadlet(tmp_path, 'priv')
        assert sections['Container']['SecurityLabelDisable'] == 'true'
        # PodmanArgs may appear multiple times; check the raw content
        assert 'PodmanArgs=--privileged' in content

    # -- Test 10: Network with Quadlet-defined network --

    def test_network_quadlet_defined(self, ns, bb_mod, d, tmp_path):
        """When network matches a NETWORKS entry, Network= gets .network suffix."""
        d.setVar('WORKDIR', str(tmp_path))
        d.setVar('CONTAINERS', 'myapp')
        d.setVar('CONTAINER_myapp_IMAGE', 'img:latest')
        d.setVar('CONTAINER_myapp_NETWORK', 'mynet')
        d.setVar('NETWORKS', 'mynet')

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'myapp')
        assert sections['Container']['Network'] == 'mynet.network'

    # -- Test 11: Network without Quadlet-defined network --

    def test_network_not_quadlet_defined(self, ns, bb_mod, d, tmp_path):
        """When network is NOT in NETWORKS, Network= is used as-is (no suffix)."""
        d.setVar('WORKDIR', str(tmp_path))
        d.setVar('CONTAINERS', 'myapp')
        d.setVar('CONTAINER_myapp_IMAGE', 'img:latest')
        d.setVar('CONTAINER_myapp_NETWORK', 'host')
        # No NETWORKS set, so 'host' is not a Quadlet-defined network

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'myapp')
        assert sections['Container']['Network'] == 'host'

    # -- Test 12: Network aliases --

    def test_network_aliases(self, ns, bb_mod, d, tmp_path):
        """Network aliases emit PodmanArgs=--network-alias for each alias."""
        self._setup_container(
            d, tmp_path, 'myapp', 'img:latest',
            NETWORK_ALIASES='alias1 alias2'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        _, content = self._read_quadlet(tmp_path, 'myapp')
        assert 'PodmanArgs=--network-alias alias1' in content
        assert 'PodmanArgs=--network-alias alias2' in content

    # -- Test 13: Pod membership --

    def test_pod_membership(self, ns, bb_mod, d, tmp_path):
        """Container with POD set emits Pod=<podname>.pod."""
        self._setup_container(d, tmp_path, 'backend', 'img:latest', POD='mypod')

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'backend')
        assert sections['Container']['Pod'] == 'mypod.pod'

    # -- Test 14: Disabled container --

    def test_disabled_container(self, ns, bb_mod, d, tmp_path):
        """Disabled container (ENABLED=0) is written to quadlets-available/."""
        self._setup_container(d, tmp_path, 'optional', 'img:latest', ENABLED='0')

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        # Should NOT be in the active quadlets directory
        active_path = tmp_path / 'quadlets' / 'optional.container'
        assert not active_path.exists()

        # Should be in the available directory
        sections, _ = self._read_quadlet(tmp_path, 'optional', available=True)
        assert sections['Container']['Image'] == 'img:latest'
        # Still has Install section so it works when manually enabled
        assert sections['Install']['WantedBy'] == 'multi-user.target'

    # -- Test 15: Dependencies (After= and Requires=) --

    def test_dependencies(self, ns, bb_mod, d, tmp_path):
        """DEPENDS_ON produces After= and Requires= for each dependency."""
        self._setup_container(
            d, tmp_path, 'webapp', 'img:latest',
            DEPENDS_ON='database cache'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, content = self._read_quadlet(tmp_path, 'webapp')

        # After and Requires should include the dependency services.
        # The Unit section may have multiple After= lines; parse_quadlet
        # collapses them into a list.
        after_values = sections['Unit']['After']
        if isinstance(after_values, str):
            after_values = [after_values]
        requires_values = sections['Unit'].get('Requires', [])
        if isinstance(requires_values, str):
            requires_values = [requires_values]

        assert 'database.service' in after_values
        assert 'cache.service' in after_values
        assert 'database.service' in requires_values
        assert 'cache.service' in requires_values

    # -- Additional container option tests --

    def test_ports(self, ns, bb_mod, d, tmp_path):
        """PORTS produces PublishPort= lines."""
        self._setup_container(
            d, tmp_path, 'web', 'nginx:alpine',
            PORTS='80:80 443:443'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'web')
        ports = sections['Container']['PublishPort']
        if isinstance(ports, str):
            ports = [ports]
        assert '80:80' in ports
        assert '443:443' in ports

    def test_volumes(self, ns, bb_mod, d, tmp_path):
        """VOLUMES produces Volume= lines."""
        self._setup_container(
            d, tmp_path, 'db', 'postgres:16',
            VOLUMES='/data/pg:/var/lib/postgresql/data:rw /config:/etc/pg:ro'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'db')
        vols = sections['Container']['Volume']
        if isinstance(vols, str):
            vols = [vols]
        assert '/data/pg:/var/lib/postgresql/data:rw' in vols
        assert '/config:/etc/pg:ro' in vols

    def test_environment(self, ns, bb_mod, d, tmp_path):
        """ENVIRONMENT produces Environment= lines."""
        self._setup_container(
            d, tmp_path, 'app', 'myapp:latest',
            ENVIRONMENT='DB_HOST=localhost DB_PORT=5432'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'app')
        envs = sections['Container']['Environment']
        if isinstance(envs, str):
            envs = [envs]
        assert 'DB_HOST=localhost' in envs
        assert 'DB_PORT=5432' in envs

    def test_restart_policy(self, ns, bb_mod, d, tmp_path):
        """Custom RESTART policy is reflected in the Service section."""
        self._setup_container(
            d, tmp_path, 'worker', 'worker:latest',
            RESTART='on-failure'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'worker')
        assert sections['Service']['Restart'] == 'on-failure'

    def test_capabilities(self, ns, bb_mod, d, tmp_path):
        """CAPS_ADD and CAPS_DROP produce capability lines."""
        self._setup_container(
            d, tmp_path, 'netapp', 'netapp:latest',
            CAPS_ADD='NET_ADMIN SYS_TIME',
            CAPS_DROP='MKNOD'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'netapp')
        adds = sections['Container']['AddCapability']
        if isinstance(adds, str):
            adds = [adds]
        assert 'NET_ADMIN' in adds
        assert 'SYS_TIME' in adds

        drops = sections['Container']['DropCapability']
        if isinstance(drops, str):
            drops = [drops]
        assert 'MKNOD' in drops

    def test_read_only(self, ns, bb_mod, d, tmp_path):
        """READ_ONLY=1 produces ReadOnly=true."""
        self._setup_container(
            d, tmp_path, 'secure', 'secure:latest',
            READ_ONLY='1'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'secure')
        assert sections['Container']['ReadOnly'] == 'true'

    def test_resource_limits(self, ns, bb_mod, d, tmp_path):
        """MEMORY_LIMIT and CPU_LIMIT produce PodmanArgs."""
        self._setup_container(
            d, tmp_path, 'limited', 'limited:latest',
            MEMORY_LIMIT='512m', CPU_LIMIT='0.5'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        _, content = self._read_quadlet(tmp_path, 'limited')
        assert 'PodmanArgs=--memory 512m' in content
        assert 'PodmanArgs=--cpus 0.5' in content

    def test_devices(self, ns, bb_mod, d, tmp_path):
        """DEVICES produces AddDevice= lines."""
        self._setup_container(
            d, tmp_path, 'hw', 'hw:latest',
            DEVICES='/dev/video0 /dev/ttyUSB0'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'hw')
        devs = sections['Container']['AddDevice']
        if isinstance(devs, str):
            devs = [devs]
        assert '/dev/video0' in devs
        assert '/dev/ttyUSB0' in devs

    def test_user_and_workdir(self, ns, bb_mod, d, tmp_path):
        """USER and WORKING_DIR produce User= and WorkingDir=."""
        self._setup_container(
            d, tmp_path, 'svc', 'svc:latest',
            USER='1000:1000', WORKING_DIR='/app'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'svc')
        assert sections['Container']['User'] == '1000:1000'
        assert sections['Container']['WorkingDir'] == '/app'

    def test_labels(self, ns, bb_mod, d, tmp_path):
        """LABELS produces Label= lines."""
        self._setup_container(
            d, tmp_path, 'labelled', 'labelled:latest',
            LABELS='env=prod version=1.0'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'labelled')
        labels = sections['Container']['Label']
        if isinstance(labels, str):
            labels = [labels]
        assert 'env=prod' in labels
        assert 'version=1.0' in labels

    def test_health_check(self, ns, bb_mod, d, tmp_path):
        """Health check options produce HealthCmd=, HealthInterval=, etc."""
        self._setup_container(
            d, tmp_path, 'healthy', 'healthy:latest',
            HEALTH_CMD='curl -f http://localhost/',
            HEALTH_INTERVAL='30s',
            HEALTH_TIMEOUT='10s',
            HEALTH_RETRIES='3',
            HEALTH_START_PERIOD='60s'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'healthy')
        assert sections['Container']['HealthCmd'] == 'curl -f http://localhost/'
        assert sections['Container']['HealthInterval'] == '30s'
        assert sections['Container']['HealthTimeout'] == '10s'
        assert sections['Container']['HealthRetries'] == '3'
        assert sections['Container']['HealthStartPeriod'] == '60s'

    def test_timezone(self, ns, bb_mod, d, tmp_path):
        """TIMEZONE produces Timezone=."""
        self._setup_container(
            d, tmp_path, 'tz', 'tz:latest',
            TIMEZONE='Europe/Rome'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'tz')
        assert sections['Container']['Timezone'] == 'Europe/Rome'

    def test_log_driver_and_opts(self, ns, bb_mod, d, tmp_path):
        """LOG_DRIVER and LOG_OPT produce LogDriver= and PodmanArgs."""
        self._setup_container(
            d, tmp_path, 'logged', 'logged:latest',
            LOG_DRIVER='journald',
            LOG_OPT='tag=mycontainer max-size=10m'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, content = self._read_quadlet(tmp_path, 'logged')
        assert sections['Container']['LogDriver'] == 'journald'
        assert 'PodmanArgs=--log-opt tag=mycontainer' in content
        assert 'PodmanArgs=--log-opt max-size=10m' in content

    def test_ulimits(self, ns, bb_mod, d, tmp_path):
        """ULIMITS produces Ulimit= lines."""
        self._setup_container(
            d, tmp_path, 'ulim', 'ulim:latest',
            ULIMITS='nofile=65536:65536 nproc=4096:4096'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'ulim')
        ulimits = sections['Container']['Ulimit']
        if isinstance(ulimits, str):
            ulimits = [ulimits]
        assert 'nofile=65536:65536' in ulimits
        assert 'nproc=4096:4096' in ulimits

    def test_stop_timeout(self, ns, bb_mod, d, tmp_path):
        """STOP_TIMEOUT produces TimeoutStopSec= in Service section."""
        self._setup_container(
            d, tmp_path, 'slow', 'slow:latest',
            STOP_TIMEOUT='30'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, _ = self._read_quadlet(tmp_path, 'slow')
        assert sections['Service']['TimeoutStopSec'] == '30'

    def test_no_containers_does_nothing(self, ns, bb_mod, d, tmp_path):
        """When CONTAINERS is empty, no files are generated."""
        d.setVar('WORKDIR', str(tmp_path))
        d.setVar('CONTAINERS', '')

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        quadlets_dir = tmp_path / 'quadlets'
        assert not quadlets_dir.exists()

    def test_entrypoint_and_command(self, ns, bb_mod, d, tmp_path):
        """ENTRYPOINT and COMMAND produce Exec= lines."""
        self._setup_container(
            d, tmp_path, 'custom', 'custom:latest',
            ENTRYPOINT='/usr/bin/myapp',
            COMMAND='--verbose --port=8080'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        _, content = self._read_quadlet(tmp_path, 'custom')
        assert 'Exec=/usr/bin/myapp' in content
        assert 'Exec=--verbose --port=8080' in content

    def test_sdnotify_container(self, ns, bb_mod, d, tmp_path):
        """SDNOTIFY=container produces Notify=true and PodmanArgs=--sdnotify container."""
        self._setup_container(
            d, tmp_path, 'notifier', 'notifier:latest',
            SDNOTIFY='container'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections, content = self._read_quadlet(tmp_path, 'notifier')
        assert sections['Container']['Notify'] == 'true'
        assert 'PodmanArgs=--sdnotify container' in content

    def test_cgroups_mode(self, ns, bb_mod, d, tmp_path):
        """CGROUPS produces PodmanArgs=--cgroups."""
        self._setup_container(
            d, tmp_path, 'cg', 'cg:latest',
            CGROUPS='no-conmon'
        )

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        _, content = self._read_quadlet(tmp_path, 'cg')
        assert 'PodmanArgs=--cgroups no-conmon' in content


# ===========================================================================
#  Pod Quadlet generation tests (do_generate_pods)
# ===========================================================================

class TestGeneratePods:
    """Tests for do_generate_pods task."""

    def _setup_pod(self, d, tmp_path, name, **extras):
        """Set up a single pod in the datastore."""
        safe = name.replace('-', '_').replace('.', '_')
        d.setVar('WORKDIR', str(tmp_path))
        d.setVar('PODS', name)
        for var, val in extras.items():
            d.setVar(f'POD_{safe}_{var}', val)

    def _read_pod(self, tmp_path, name, available=False):
        """Read and parse a generated .pod quadlet file."""
        subdir = 'quadlets-available' if available else 'quadlets'
        path = tmp_path / subdir / f'{name}.pod'
        assert path.exists(), f"Expected pod file not found: {path}"
        content = path.read_text()
        return parse_quadlet(content), content

    # -- Test 16: Basic pod --

    def test_basic_pod(self, ns, bb_mod, d, tmp_path):
        """A basic pod generates a .pod file with PodName=."""
        self._setup_pod(d, tmp_path, 'mypod')

        _run_task(ns, 'do_generate_pods', d, bb_mod)

        sections, _ = self._read_pod(tmp_path, 'mypod')
        assert sections['Unit']['Description'] == 'mypod pod'
        assert sections['Pod']['PodName'] == 'mypod'
        assert sections['Install']['WantedBy'] == 'multi-user.target'

    # -- Test 17: Pod network with Quadlet-defined network --

    def test_pod_network_quadlet_defined(self, ns, bb_mod, d, tmp_path):
        """When pod network matches NETWORKS, Network= gets .network suffix."""
        d.setVar('WORKDIR', str(tmp_path))
        d.setVar('PODS', 'mypod')
        d.setVar('POD_mypod_NETWORK', 'mynet')
        d.setVar('NETWORKS', 'mynet')

        _run_task(ns, 'do_generate_pods', d, bb_mod)

        sections, _ = self._read_pod(tmp_path, 'mypod')
        assert sections['Pod']['Network'] == 'mynet.network'

    # -- Test 18: Pod network without Quadlet-defined network --

    def test_pod_network_plain(self, ns, bb_mod, d, tmp_path):
        """When pod network is NOT in NETWORKS, Network= is plain (no suffix)."""
        d.setVar('WORKDIR', str(tmp_path))
        d.setVar('PODS', 'mypod')
        d.setVar('POD_mypod_NETWORK', 'bridge')

        _run_task(ns, 'do_generate_pods', d, bb_mod)

        sections, _ = self._read_pod(tmp_path, 'mypod')
        assert sections['Pod']['Network'] == 'bridge'

    def test_pod_ports(self, ns, bb_mod, d, tmp_path):
        """PORTS on a pod produce PublishPort= lines."""
        self._setup_pod(d, tmp_path, 'webpod', PORTS='8080:8080 8443:8443')

        _run_task(ns, 'do_generate_pods', d, bb_mod)

        sections, _ = self._read_pod(tmp_path, 'webpod')
        ports = sections['Pod']['PublishPort']
        if isinstance(ports, str):
            ports = [ports]
        assert '8080:8080' in ports
        assert '8443:8443' in ports

    def test_pod_volumes(self, ns, bb_mod, d, tmp_path):
        """VOLUMES on a pod produce Volume= lines."""
        self._setup_pod(d, tmp_path, 'datapod', VOLUMES='/shared:/shared:rw')

        _run_task(ns, 'do_generate_pods', d, bb_mod)

        sections, _ = self._read_pod(tmp_path, 'datapod')
        assert sections['Pod']['Volume'] == '/shared:/shared:rw'

    def test_pod_dns(self, ns, bb_mod, d, tmp_path):
        """DNS on a pod produces DNS= lines."""
        self._setup_pod(d, tmp_path, 'dnspod', DNS='8.8.8.8 8.8.4.4')

        _run_task(ns, 'do_generate_pods', d, bb_mod)

        sections, _ = self._read_pod(tmp_path, 'dnspod')
        dns = sections['Pod']['DNS']
        if isinstance(dns, str):
            dns = [dns]
        assert '8.8.8.8' in dns
        assert '8.8.4.4' in dns

    def test_pod_hostname(self, ns, bb_mod, d, tmp_path):
        """HOSTNAME on a pod produces Hostname=."""
        self._setup_pod(d, tmp_path, 'hpod', HOSTNAME='my-host')

        _run_task(ns, 'do_generate_pods', d, bb_mod)

        sections, _ = self._read_pod(tmp_path, 'hpod')
        assert sections['Pod']['Hostname'] == 'my-host'

    def test_pod_labels(self, ns, bb_mod, d, tmp_path):
        """LABELS on a pod produce Label= lines."""
        self._setup_pod(d, tmp_path, 'lpod', LABELS='env=staging team=platform')

        _run_task(ns, 'do_generate_pods', d, bb_mod)

        sections, _ = self._read_pod(tmp_path, 'lpod')
        labels = sections['Pod']['Label']
        if isinstance(labels, str):
            labels = [labels]
        assert 'env=staging' in labels
        assert 'team=platform' in labels

    def test_pod_disabled(self, ns, bb_mod, d, tmp_path):
        """Disabled pod (ENABLED=0) is written to quadlets-available/."""
        self._setup_pod(d, tmp_path, 'offpod', ENABLED='0')

        _run_task(ns, 'do_generate_pods', d, bb_mod)

        active = tmp_path / 'quadlets' / 'offpod.pod'
        assert not active.exists()

        sections, _ = self._read_pod(tmp_path, 'offpod', available=True)
        assert sections['Pod']['PodName'] == 'offpod'

    def test_pod_ip_mac(self, ns, bb_mod, d, tmp_path):
        """IP and MAC on a pod produce IP= and MAC=."""
        self._setup_pod(
            d, tmp_path, 'staticpod',
            IP='10.89.0.10', MAC='02:42:ac:11:00:02'
        )

        _run_task(ns, 'do_generate_pods', d, bb_mod)

        sections, _ = self._read_pod(tmp_path, 'staticpod')
        assert sections['Pod']['IP'] == '10.89.0.10'
        assert sections['Pod']['MAC'] == '02:42:ac:11:00:02'

    def test_no_pods_does_nothing(self, ns, bb_mod, d, tmp_path):
        """When PODS is empty, no files are generated."""
        d.setVar('WORKDIR', str(tmp_path))
        d.setVar('PODS', '')

        _run_task(ns, 'do_generate_pods', d, bb_mod)

        quadlets_dir = tmp_path / 'quadlets'
        assert not quadlets_dir.exists()


# ===========================================================================
#  Network Quadlet generation tests (do_generate_networks)
# ===========================================================================

class TestGenerateNetworks:
    """Tests for do_generate_networks task."""

    def _setup_network(self, d, tmp_path, name, **extras):
        """Set up a single network in the datastore."""
        safe = name.replace('-', '_').replace('.', '_')
        d.setVar('WORKDIR', str(tmp_path))
        d.setVar('NETWORKS', name)
        for var, val in extras.items():
            d.setVar(f'NETWORK_{safe}_{var}', val)

    def _read_network(self, tmp_path, name, available=False):
        """Read and parse a generated .network quadlet file."""
        subdir = 'quadlets-available' if available else 'quadlets'
        path = tmp_path / subdir / f'{name}.network'
        assert path.exists(), f"Expected network file not found: {path}"
        content = path.read_text()
        return parse_quadlet(content), content

    # -- Test 19: Basic network --

    def test_basic_network(self, ns, bb_mod, d, tmp_path):
        """A basic network generates a .network file with NetworkName=."""
        self._setup_network(d, tmp_path, 'appnet')

        _run_task(ns, 'do_generate_networks', d, bb_mod)

        sections, _ = self._read_network(tmp_path, 'appnet')
        assert sections['Unit']['Description'] == 'appnet network'
        assert sections['Network']['NetworkName'] == 'appnet'
        assert sections['Install']['WantedBy'] == 'multi-user.target'

    # -- Test 20: Full network configuration --

    def test_full_network_config(self, ns, bb_mod, d, tmp_path):
        """Network with all options generates complete Quadlet."""
        self._setup_network(
            d, tmp_path, 'fullnet',
            DRIVER='bridge',
            SUBNET='10.89.0.0/24',
            GATEWAY='10.89.0.1',
            IP_RANGE='10.89.0.128/25',
            IPV6='1',
            INTERNAL='1',
            DNS='8.8.8.8 1.1.1.1',
            LABELS='env=test scope=ci',
            OPTIONS='mtu=9000 vlan=100'
        )

        _run_task(ns, 'do_generate_networks', d, bb_mod)

        sections, _ = self._read_network(tmp_path, 'fullnet')
        net = sections['Network']

        assert net['NetworkName'] == 'fullnet'
        assert net['Driver'] == 'bridge'
        assert net['Subnet'] == '10.89.0.0/24'
        assert net['Gateway'] == '10.89.0.1'
        assert net['IPRange'] == '10.89.0.128/25'
        assert net['IPv6'] == 'true'
        assert net['Internal'] == 'true'

        dns = net['DNS']
        if isinstance(dns, str):
            dns = [dns]
        assert '8.8.8.8' in dns
        assert '1.1.1.1' in dns

        labels = net['Label']
        if isinstance(labels, str):
            labels = [labels]
        assert 'env=test' in labels
        assert 'scope=ci' in labels

        opts = net['Options']
        if isinstance(opts, str):
            opts = [opts]
        assert 'mtu=9000' in opts
        assert 'vlan=100' in opts

    # -- Test 21: Disabled network --

    def test_disabled_network(self, ns, bb_mod, d, tmp_path):
        """Disabled network (ENABLED=0) is written to quadlets-available/."""
        self._setup_network(d, tmp_path, 'offnet', ENABLED='0')

        _run_task(ns, 'do_generate_networks', d, bb_mod)

        active = tmp_path / 'quadlets' / 'offnet.network'
        assert not active.exists()

        sections, _ = self._read_network(tmp_path, 'offnet', available=True)
        assert sections['Network']['NetworkName'] == 'offnet'

    def test_no_networks_does_nothing(self, ns, bb_mod, d, tmp_path):
        """When NETWORKS is empty, no files are generated."""
        d.setVar('WORKDIR', str(tmp_path))
        d.setVar('NETWORKS', '')

        _run_task(ns, 'do_generate_networks', d, bb_mod)

        quadlets_dir = tmp_path / 'quadlets'
        assert not quadlets_dir.exists()

    def test_network_with_dashes(self, ns, bb_mod, d, tmp_path):
        """Network names with dashes are handled correctly."""
        self._setup_network(
            d, tmp_path, 'my-custom-net',
            DRIVER='macvlan',
            SUBNET='192.168.1.0/24'
        )

        _run_task(ns, 'do_generate_networks', d, bb_mod)

        sections, _ = self._read_network(tmp_path, 'my-custom-net')
        assert sections['Network']['NetworkName'] == 'my-custom-net'
        assert sections['Network']['Driver'] == 'macvlan'
        assert sections['Network']['Subnet'] == '192.168.1.0/24'


# ===========================================================================
#  Integration tests
# ===========================================================================

class TestIntegration:
    """Integration tests combining networks, pods, and containers."""

    # -- Test 22: Full stack with networks + containers --

    def test_network_and_container_suffix(self, ns, bb_mod, d, tmp_path):
        """Containers referencing a Quadlet-defined network get the .network suffix."""
        d.setVar('WORKDIR', str(tmp_path))

        # Define a network
        d.setVar('NETWORKS', 'appnet')
        d.setVar('NETWORK_appnet_DRIVER', 'bridge')
        d.setVar('NETWORK_appnet_SUBNET', '10.89.0.0/24')
        d.setVar('NETWORK_appnet_GATEWAY', '10.89.0.1')

        # Define containers that use the network
        d.setVar('CONTAINERS', 'frontend backend')
        d.setVar('CONTAINER_frontend_IMAGE', 'nginx:alpine')
        d.setVar('CONTAINER_frontend_NETWORK', 'appnet')
        d.setVar('CONTAINER_frontend_PORTS', '80:80')
        d.setVar('CONTAINER_frontend_NETWORK_ALIASES', 'web')

        d.setVar('CONTAINER_backend_IMAGE', 'myapi:latest')
        d.setVar('CONTAINER_backend_NETWORK', 'appnet')
        d.setVar('CONTAINER_backend_NETWORK_ALIASES', 'api')

        # Generate network
        _run_task(ns, 'do_generate_networks', d, bb_mod)

        # Generate container quadlets
        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        # Verify network file
        net_path = tmp_path / 'quadlets' / 'appnet.network'
        assert net_path.exists()
        net_sections = parse_quadlet(net_path.read_text())
        assert net_sections['Network']['NetworkName'] == 'appnet'
        assert net_sections['Network']['Subnet'] == '10.89.0.0/24'

        # Verify frontend container
        fe_path = tmp_path / 'quadlets' / 'frontend.container'
        assert fe_path.exists()
        fe_content = fe_path.read_text()
        fe_sections = parse_quadlet(fe_content)
        assert fe_sections['Container']['Network'] == 'appnet.network'
        assert fe_sections['Container']['Image'] == 'nginx:alpine'
        assert 'PodmanArgs=--network-alias web' in fe_content

        # Verify backend container
        be_path = tmp_path / 'quadlets' / 'backend.container'
        assert be_path.exists()
        be_content = be_path.read_text()
        be_sections = parse_quadlet(be_content)
        assert be_sections['Container']['Network'] == 'appnet.network'
        assert 'PodmanArgs=--network-alias api' in be_content

    # -- Test 23: Full stack with pods + containers --

    def test_pods_and_container_members(self, ns, bb_mod, d, tmp_path):
        """Containers as pod members reference the pod via Pod=<name>.pod."""
        d.setVar('WORKDIR', str(tmp_path))

        # Define a pod
        d.setVar('PODS', 'myapp')
        d.setVar('POD_myapp_PORTS', '8080:8080 8443:8443')
        d.setVar('POD_myapp_NETWORK', 'bridge')

        # Define containers that belong to the pod
        d.setVar('CONTAINERS', 'myapp-backend myapp-frontend')
        d.setVar('CONTAINER_myapp_backend_IMAGE', 'backend:v1')
        d.setVar('CONTAINER_myapp_backend_POD', 'myapp')
        d.setVar('CONTAINER_myapp_frontend_IMAGE', 'frontend:v1')
        d.setVar('CONTAINER_myapp_frontend_POD', 'myapp')

        # Generate pods
        _run_task(ns, 'do_generate_pods', d, bb_mod)

        # Generate container quadlets
        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        # Verify pod file
        pod_path = tmp_path / 'quadlets' / 'myapp.pod'
        assert pod_path.exists()
        pod_sections = parse_quadlet(pod_path.read_text())
        assert pod_sections['Pod']['PodName'] == 'myapp'
        ports = pod_sections['Pod']['PublishPort']
        if isinstance(ports, str):
            ports = [ports]
        assert '8080:8080' in ports
        assert '8443:8443' in ports
        assert pod_sections['Pod']['Network'] == 'bridge'

        # Verify backend container is a pod member
        be_path = tmp_path / 'quadlets' / 'myapp-backend.container'
        assert be_path.exists()
        be_sections = parse_quadlet(be_path.read_text())
        assert be_sections['Container']['Pod'] == 'myapp.pod'
        assert be_sections['Container']['Image'] == 'backend:v1'

        # Verify frontend container is a pod member
        fe_path = tmp_path / 'quadlets' / 'myapp-frontend.container'
        assert fe_path.exists()
        fe_sections = parse_quadlet(fe_path.read_text())
        assert fe_sections['Container']['Pod'] == 'myapp.pod'
        assert fe_sections['Container']['Image'] == 'frontend:v1'

    def test_mixed_enabled_disabled(self, ns, bb_mod, d, tmp_path):
        """Mix of enabled and disabled containers/networks go to correct dirs."""
        d.setVar('WORKDIR', str(tmp_path))

        # Networks: one active, one disabled
        d.setVar('NETWORKS', 'prodnet devnet')
        d.setVar('NETWORK_prodnet_DRIVER', 'bridge')
        d.setVar('NETWORK_devnet_DRIVER', 'bridge')
        d.setVar('NETWORK_devnet_ENABLED', '0')

        # Containers: one active, one disabled
        d.setVar('CONTAINERS', 'webapp debugger')
        d.setVar('CONTAINER_webapp_IMAGE', 'webapp:latest')
        d.setVar('CONTAINER_webapp_NETWORK', 'prodnet')
        d.setVar('CONTAINER_debugger_IMAGE', 'debugger:latest')
        d.setVar('CONTAINER_debugger_ENABLED', '0')

        _run_task(ns, 'do_generate_networks', d, bb_mod)
        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        # Active items in quadlets/
        assert (tmp_path / 'quadlets' / 'prodnet.network').exists()
        assert (tmp_path / 'quadlets' / 'webapp.container').exists()

        # Disabled items in quadlets-available/
        assert (tmp_path / 'quadlets-available' / 'devnet.network').exists()
        assert (tmp_path / 'quadlets-available' / 'debugger.container').exists()

        # Verify they are NOT in the wrong directory
        assert not (tmp_path / 'quadlets' / 'devnet.network').exists()
        assert not (tmp_path / 'quadlets' / 'debugger.container').exists()
        assert not (tmp_path / 'quadlets-available' / 'prodnet.network').exists()
        assert not (tmp_path / 'quadlets-available' / 'webapp.container').exists()

    def test_full_stack_networks_pods_containers(self, ns, bb_mod, d, tmp_path):
        """Complete deployment: network + pod + containers all wired together."""
        d.setVar('WORKDIR', str(tmp_path))

        # Network
        d.setVar('NETWORKS', 'iotnet')
        d.setVar('NETWORK_iotnet_DRIVER', 'bridge')
        d.setVar('NETWORK_iotnet_SUBNET', '10.10.0.0/24')

        # Pod using the network
        d.setVar('PODS', 'iot-stack')
        d.setVar('POD_iot_stack_PORTS', '1883:1883 8883:8883')
        d.setVar('POD_iot_stack_NETWORK', 'iotnet')

        # Containers in the pod
        d.setVar('CONTAINERS', 'mqtt-broker iot-gateway')
        d.setVar('CONTAINER_mqtt_broker_IMAGE', 'eclipse-mosquitto:2.0')
        d.setVar('CONTAINER_mqtt_broker_POD', 'iot-stack')
        d.setVar('CONTAINER_mqtt_broker_VOLUMES', '/data/mqtt:/mosquitto/data:rw')

        d.setVar('CONTAINER_iot_gateway_IMAGE', 'iot-gw:latest')
        d.setVar('CONTAINER_iot_gateway_POD', 'iot-stack')
        d.setVar('CONTAINER_iot_gateway_ENVIRONMENT', 'MQTT_HOST=localhost MQTT_PORT=1883')
        d.setVar('CONTAINER_iot_gateway_DEPENDS_ON', 'mqtt-broker')

        # Generate everything
        _run_task(ns, 'do_generate_networks', d, bb_mod)
        _run_task(ns, 'do_generate_pods', d, bb_mod)
        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        # Verify network
        net = parse_quadlet((tmp_path / 'quadlets' / 'iotnet.network').read_text())
        assert net['Network']['NetworkName'] == 'iotnet'
        assert net['Network']['Subnet'] == '10.10.0.0/24'

        # Verify pod references the Quadlet-defined network with suffix
        pod = parse_quadlet((tmp_path / 'quadlets' / 'iot-stack.pod').read_text())
        assert pod['Pod']['PodName'] == 'iot-stack'
        assert pod['Pod']['Network'] == 'iotnet.network'

        # Verify mqtt-broker container
        mqtt = parse_quadlet((tmp_path / 'quadlets' / 'mqtt-broker.container').read_text())
        assert mqtt['Container']['Image'] == 'eclipse-mosquitto:2.0'
        assert mqtt['Container']['Pod'] == 'iot-stack.pod'
        assert mqtt['Container']['Volume'] == '/data/mqtt:/mosquitto/data:rw'

        # Verify iot-gateway container with dependency
        gw_content = (tmp_path / 'quadlets' / 'iot-gateway.container').read_text()
        gw = parse_quadlet(gw_content)
        assert gw['Container']['Image'] == 'iot-gw:latest'
        assert gw['Container']['Pod'] == 'iot-stack.pod'

        envs = gw['Container']['Environment']
        if isinstance(envs, str):
            envs = [envs]
        assert 'MQTT_HOST=localhost' in envs
        assert 'MQTT_PORT=1883' in envs

        # Dependency wiring
        after = gw['Unit']['After']
        if isinstance(after, str):
            after = [after]
        assert 'mqtt-broker.service' in after

    def test_container_with_non_quadlet_network_no_suffix(self, ns, bb_mod, d, tmp_path):
        """Container using a network NOT in NETWORKS does not get .network suffix."""
        d.setVar('WORKDIR', str(tmp_path))

        # Define a different network in NETWORKS
        d.setVar('NETWORKS', 'internal-only')
        d.setVar('NETWORK_internal_only_DRIVER', 'bridge')

        # Container uses 'host' network which is NOT Quadlet-defined
        d.setVar('CONTAINERS', 'hostapp')
        d.setVar('CONTAINER_hostapp_IMAGE', 'hostapp:latest')
        d.setVar('CONTAINER_hostapp_NETWORK', 'host')

        _run_task(ns, 'do_generate_quadlets', d, bb_mod)

        sections = parse_quadlet(
            (tmp_path / 'quadlets' / 'hostapp.container').read_text()
        )
        # 'host' should NOT become 'host.network'
        assert sections['Container']['Network'] == 'host'
