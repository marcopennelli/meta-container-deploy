# SPDX-License-Identifier: MIT
"""
Tests for container-pod.bbclass - Podman Quadlet pod unit generation.

Covers:
  - Basic pod generation with minimal config
  - Port mappings, network, volumes, labels
  - DNS, DNS search, hostname, static IP/MAC
  - Add-host entries, user namespace
  - Disabled pods (quadlets-available/)
  - Full config with all options
  - Validation (missing POD_NAME, host network warning)
"""

import os
import pytest

from conftest import (
    BBFatalError,
    MockBB,
    MockDataStore,
    load_bbclass,
    parse_quadlet,
)

BBCLASS = os.path.join(
    os.path.dirname(os.path.dirname(__file__)), "classes", "container-pod.bbclass"
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _setup_datastore(tmp_path, overrides=None):
    """Return a MockDataStore pre-populated with WORKDIR and defaults.

    *overrides* is a dict of variable names to values that override the
    defaults.  Setting a key to ``None`` will skip setting that variable
    entirely, which is useful for testing missing-variable validation.
    """
    d = MockDataStore()
    d.setVar("WORKDIR", str(tmp_path))
    d.setVar("POD_NAME", "testpod")
    d.setVar("POD_PORTS", "")
    d.setVar("POD_NETWORK", "")
    d.setVar("POD_VOLUMES", "")
    d.setVar("POD_LABELS", "")
    d.setVar("POD_DNS", "")
    d.setVar("POD_DNS_SEARCH", "")
    d.setVar("POD_HOSTNAME", "")
    d.setVar("POD_IP", "")
    d.setVar("POD_MAC", "")
    d.setVar("POD_ADD_HOST", "")
    d.setVar("POD_USERNS", "")
    d.setVar("POD_ENABLED", "1")

    if overrides:
        for key, val in overrides.items():
            if val is None:
                d.delVar(key)
            else:
                d.setVar(key, val)

    return d


def _generate(tmp_path, mock_bb, overrides=None):
    """Shortcut: create datastore, load bbclass, run do_generate_pod.

    Returns (parsed_sections, raw_content, file_path).
    """
    d = _setup_datastore(tmp_path, overrides)
    ns = load_bbclass(BBCLASS, mock_bb)
    ns["do_generate_pod"](d, mock_bb)

    pod_name = d.getVar("POD_NAME")
    enabled = d.getVar("POD_ENABLED")

    if enabled == "0":
        pod_file = tmp_path / "quadlets-available" / f"{pod_name}.pod"
    else:
        pod_file = tmp_path / "quadlets" / f"{pod_name}.pod"

    content = pod_file.read_text()
    sections = parse_quadlet(content)
    return sections, content, str(pod_file)


# ---------------------------------------------------------------------------
# 1. Basic pod - minimal config
# ---------------------------------------------------------------------------

class TestBasicPod:
    """Minimal config: only POD_NAME is meaningful; all optionals are empty."""

    def test_sections_present(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert "Unit" in sections
        assert "Pod" in sections
        assert "Install" in sections

    def test_pod_name_set(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert sections["Pod"]["PodName"] == "testpod"

    def test_unit_description(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert "testpod" in sections["Unit"]["Description"]

    def test_unit_after(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        after = sections["Unit"]["After"]
        assert "network-online.target" in after
        assert "container-import.service" in after

    def test_unit_wants(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert sections["Unit"]["Wants"] == "network-online.target"

    def test_install_wanted_by(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert sections["Install"]["WantedBy"] == "multi-user.target"

    def test_file_placed_in_quadlets(self, tmp_path, mock_bb):
        _, _, path = _generate(tmp_path, mock_bb)
        assert "/quadlets/testpod.pod" in path
        assert os.path.isfile(path)

    def test_no_optional_keys(self, tmp_path, mock_bb):
        """When optionals are empty the Pod section contains only PodName."""
        sections, _, _ = _generate(tmp_path, mock_bb)
        pod = sections["Pod"]
        assert list(pod.keys()) == ["PodName"]


# ---------------------------------------------------------------------------
# 2. Ports
# ---------------------------------------------------------------------------

class TestPorts:

    def test_single_port(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, {"POD_PORTS": "8080:80"})
        assert sections["Pod"]["PublishPort"] == "8080:80"

    def test_multiple_ports(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_PORTS": "8080:80 8443:443 9090:9090/tcp"}
        )
        ports = sections["Pod"]["PublishPort"]
        assert isinstance(ports, list)
        assert ports == ["8080:80", "8443:443", "9090:9090/tcp"]

    def test_no_ports_key_when_empty(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, {"POD_PORTS": ""})
        assert "PublishPort" not in sections["Pod"]


# ---------------------------------------------------------------------------
# 3. Network
# ---------------------------------------------------------------------------

class TestNetwork:

    def test_bridge_network(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, {"POD_NETWORK": "bridge"})
        assert sections["Pod"]["Network"] == "bridge"

    def test_custom_network(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, {"POD_NETWORK": "mynet"})
        assert sections["Pod"]["Network"] == "mynet"

    def test_no_network_key_when_empty(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert "Network" not in sections["Pod"]


# ---------------------------------------------------------------------------
# 4. Volumes
# ---------------------------------------------------------------------------

class TestVolumes:

    def test_single_volume(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_VOLUMES": "/data:/data:ro"}
        )
        assert sections["Pod"]["Volume"] == "/data:/data:ro"

    def test_multiple_volumes(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path,
            mock_bb,
            {"POD_VOLUMES": "/data:/data:ro /config:/config /logs:/var/log"},
        )
        vols = sections["Pod"]["Volume"]
        assert isinstance(vols, list)
        assert vols == ["/data:/data:ro", "/config:/config", "/logs:/var/log"]

    def test_no_volume_key_when_empty(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert "Volume" not in sections["Pod"]


# ---------------------------------------------------------------------------
# 5. Labels
# ---------------------------------------------------------------------------

class TestLabels:

    def test_single_label(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_LABELS": "app=myapp"}
        )
        assert sections["Pod"]["Label"] == "app=myapp"

    def test_multiple_labels(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_LABELS": "app=myapp env=prod tier=frontend"}
        )
        labels = sections["Pod"]["Label"]
        assert isinstance(labels, list)
        assert labels == ["app=myapp", "env=prod", "tier=frontend"]

    def test_label_without_equals_is_skipped(self, tmp_path, mock_bb):
        """Labels that do not contain '=' are silently dropped."""
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_LABELS": "badlabel app=myapp"}
        )
        # Only "app=myapp" should appear
        assert sections["Pod"]["Label"] == "app=myapp"

    def test_no_label_key_when_empty(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert "Label" not in sections["Pod"]


# ---------------------------------------------------------------------------
# 6. DNS
# ---------------------------------------------------------------------------

class TestDNS:

    def test_single_dns(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, {"POD_DNS": "8.8.8.8"})
        assert sections["Pod"]["DNS"] == "8.8.8.8"

    def test_multiple_dns(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_DNS": "8.8.8.8 1.1.1.1 9.9.9.9"}
        )
        dns = sections["Pod"]["DNS"]
        assert isinstance(dns, list)
        assert dns == ["8.8.8.8", "1.1.1.1", "9.9.9.9"]

    def test_no_dns_key_when_empty(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert "DNS" not in sections["Pod"]


# ---------------------------------------------------------------------------
# 7. DNS Search
# ---------------------------------------------------------------------------

class TestDNSSearch:

    def test_single_search_domain(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_DNS_SEARCH": "example.com"}
        )
        assert sections["Pod"]["DNSSearch"] == "example.com"

    def test_multiple_search_domains(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_DNS_SEARCH": "example.com internal.local"}
        )
        domains = sections["Pod"]["DNSSearch"]
        assert isinstance(domains, list)
        assert domains == ["example.com", "internal.local"]

    def test_no_dns_search_key_when_empty(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert "DNSSearch" not in sections["Pod"]


# ---------------------------------------------------------------------------
# 8. Hostname
# ---------------------------------------------------------------------------

class TestHostname:

    def test_hostname_set(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_HOSTNAME": "mypod.local"}
        )
        assert sections["Pod"]["Hostname"] == "mypod.local"

    def test_no_hostname_key_when_empty(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert "Hostname" not in sections["Pod"]


# ---------------------------------------------------------------------------
# 9. Static IP
# ---------------------------------------------------------------------------

class TestStaticIP:

    def test_ip_set(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_IP": "10.88.0.100"}
        )
        assert sections["Pod"]["IP"] == "10.88.0.100"

    def test_no_ip_key_when_empty(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert "IP" not in sections["Pod"]


# ---------------------------------------------------------------------------
# 10. Static MAC
# ---------------------------------------------------------------------------

class TestStaticMAC:

    def test_mac_set(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_MAC": "aa:bb:cc:dd:ee:ff"}
        )
        assert sections["Pod"]["MAC"] == "aa:bb:cc:dd:ee:ff"

    def test_no_mac_key_when_empty(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert "MAC" not in sections["Pod"]


# ---------------------------------------------------------------------------
# 11. Add Host
# ---------------------------------------------------------------------------

class TestAddHost:

    def test_single_add_host(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_ADD_HOST": "db:10.0.0.5"}
        )
        assert sections["Pod"]["AddHost"] == "db:10.0.0.5"

    def test_multiple_add_hosts(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path,
            mock_bb,
            {"POD_ADD_HOST": "db:10.0.0.5 cache:10.0.0.6 api:10.0.0.7"},
        )
        hosts = sections["Pod"]["AddHost"]
        assert isinstance(hosts, list)
        assert hosts == ["db:10.0.0.5", "cache:10.0.0.6", "api:10.0.0.7"]

    def test_no_add_host_key_when_empty(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert "AddHost" not in sections["Pod"]


# ---------------------------------------------------------------------------
# 12. User Namespace
# ---------------------------------------------------------------------------

class TestUserns:

    def test_userns_set(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_USERNS": "keep-id"}
        )
        assert sections["Pod"]["Userns"] == "keep-id"

    def test_userns_auto(self, tmp_path, mock_bb):
        sections, _, _ = _generate(
            tmp_path, mock_bb, {"POD_USERNS": "auto"}
        )
        assert sections["Pod"]["Userns"] == "auto"

    def test_no_userns_key_when_empty(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb)
        assert "Userns" not in sections["Pod"]


# ---------------------------------------------------------------------------
# 13. Disabled pod (POD_ENABLED = "0")
# ---------------------------------------------------------------------------

class TestDisabledPod:

    def test_placed_in_quadlets_available(self, tmp_path, mock_bb):
        _, _, path = _generate(tmp_path, mock_bb, {"POD_ENABLED": "0"})
        assert "/quadlets-available/" in path
        assert path.endswith("testpod.pod")
        assert os.path.isfile(path)

    def test_not_in_active_quadlets(self, tmp_path, mock_bb):
        _generate(tmp_path, mock_bb, {"POD_ENABLED": "0"})
        active = tmp_path / "quadlets" / "testpod.pod"
        assert not active.exists()

    def test_install_section_still_present(self, tmp_path, mock_bb):
        """Even disabled pods get a proper [Install] so they work when moved."""
        sections, _, _ = _generate(tmp_path, mock_bb, {"POD_ENABLED": "0"})
        assert sections["Install"]["WantedBy"] == "multi-user.target"

    def test_content_is_valid(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, {"POD_ENABLED": "0"})
        assert sections["Pod"]["PodName"] == "testpod"
        assert "Unit" in sections


# ---------------------------------------------------------------------------
# 14. Full config - all options set
# ---------------------------------------------------------------------------

class TestFullConfig:

    FULL_OVERRIDES = {
        "POD_NAME": "fullpod",
        "POD_PORTS": "8080:80 8443:443",
        "POD_NETWORK": "appnet",
        "POD_VOLUMES": "/data:/data:ro /config:/config",
        "POD_LABELS": "app=fullpod env=staging",
        "POD_DNS": "8.8.8.8 1.1.1.1",
        "POD_DNS_SEARCH": "example.com corp.local",
        "POD_HOSTNAME": "fullpod.local",
        "POD_IP": "10.88.0.50",
        "POD_MAC": "02:42:ac:11:00:02",
        "POD_ADD_HOST": "db:10.0.0.5 cache:10.0.0.6",
        "POD_USERNS": "keep-id",
        "POD_ENABLED": "1",
    }

    def test_all_sections_present(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert "Unit" in sections
        assert "Pod" in sections
        assert "Install" in sections

    def test_pod_name(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert sections["Pod"]["PodName"] == "fullpod"

    def test_ports(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert sections["Pod"]["PublishPort"] == ["8080:80", "8443:443"]

    def test_network(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert sections["Pod"]["Network"] == "appnet"

    def test_volumes(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert sections["Pod"]["Volume"] == ["/data:/data:ro", "/config:/config"]

    def test_labels(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert sections["Pod"]["Label"] == ["app=fullpod", "env=staging"]

    def test_dns(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert sections["Pod"]["DNS"] == ["8.8.8.8", "1.1.1.1"]

    def test_dns_search(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert sections["Pod"]["DNSSearch"] == ["example.com", "corp.local"]

    def test_hostname(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert sections["Pod"]["Hostname"] == "fullpod.local"

    def test_ip(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert sections["Pod"]["IP"] == "10.88.0.50"

    def test_mac(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert sections["Pod"]["MAC"] == "02:42:ac:11:00:02"

    def test_add_host(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert sections["Pod"]["AddHost"] == ["db:10.0.0.5", "cache:10.0.0.6"]

    def test_userns(self, tmp_path, mock_bb):
        sections, _, _ = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert sections["Pod"]["Userns"] == "keep-id"

    def test_file_location(self, tmp_path, mock_bb):
        _, _, path = _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert path.endswith("/quadlets/fullpod.pod")

    def test_bb_note_emitted(self, tmp_path, mock_bb):
        _generate(tmp_path, mock_bb, self.FULL_OVERRIDES)
        assert any("fullpod.pod" in n for n in mock_bb.notes)


# ---------------------------------------------------------------------------
# 15. Validation - missing POD_NAME
# ---------------------------------------------------------------------------

class TestValidation:

    def test_missing_pod_name_raises(self, tmp_path, mock_bb):
        d = _setup_datastore(tmp_path, {"POD_NAME": None})
        ns = load_bbclass(BBCLASS, mock_bb)

        with pytest.raises(BBFatalError, match="POD_NAME must be set"):
            ns["do_validate_pod"](d, mock_bb)

    def test_missing_pod_name_empty_string(self, tmp_path, mock_bb):
        """An empty string is falsy, so it should also trigger validation."""
        d = _setup_datastore(tmp_path, {"POD_NAME": ""})
        ns = load_bbclass(BBCLASS, mock_bb)

        with pytest.raises(BBFatalError, match="POD_NAME must be set"):
            ns["do_validate_pod"](d, mock_bb)

    def test_fatal_message_recorded(self, tmp_path, mock_bb):
        d = _setup_datastore(tmp_path, {"POD_NAME": None})
        ns = load_bbclass(BBCLASS, mock_bb)

        with pytest.raises(BBFatalError):
            ns["do_validate_pod"](d, mock_bb)

        assert len(mock_bb.fatals) == 1
        assert "POD_NAME" in mock_bb.fatals[0]

    def test_valid_pod_name_passes(self, tmp_path, mock_bb):
        """Normal case: validation should not raise."""
        d = _setup_datastore(tmp_path)
        ns = load_bbclass(BBCLASS, mock_bb)
        ns["do_validate_pod"](d, mock_bb)
        assert mock_bb.fatals == []


# ---------------------------------------------------------------------------
# 16. Host network warning
# ---------------------------------------------------------------------------

class TestHostNetworkWarning:

    def test_host_network_emits_warning(self, tmp_path, mock_bb):
        d = _setup_datastore(tmp_path, {"POD_NETWORK": "host"})
        ns = load_bbclass(BBCLASS, mock_bb)
        ns["do_validate_pod"](d, mock_bb)

        assert len(mock_bb.warnings) == 1
        assert "host networking" in mock_bb.warnings[0]
        assert "testpod" in mock_bb.warnings[0]

    def test_bridge_network_no_warning(self, tmp_path, mock_bb):
        d = _setup_datastore(tmp_path, {"POD_NETWORK": "bridge"})
        ns = load_bbclass(BBCLASS, mock_bb)
        ns["do_validate_pod"](d, mock_bb)
        assert mock_bb.warnings == []

    def test_empty_network_no_warning(self, tmp_path, mock_bb):
        d = _setup_datastore(tmp_path)
        ns = load_bbclass(BBCLASS, mock_bb)
        ns["do_validate_pod"](d, mock_bb)
        assert mock_bb.warnings == []

    def test_custom_network_no_warning(self, tmp_path, mock_bb):
        d = _setup_datastore(tmp_path, {"POD_NETWORK": "mynet"})
        ns = load_bbclass(BBCLASS, mock_bb)
        ns["do_validate_pod"](d, mock_bb)
        assert mock_bb.warnings == []
