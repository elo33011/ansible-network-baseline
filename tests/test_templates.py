"""
Unit tests for the Jinja2 templates in roles/network_baseline/templates/.

These render the templates directly against sample data with plain
Jinja2 (no Ansible, no network device) so they run fast and reliably in
CI on every push/PR, before anyone is allowed to run the real playbooks
against a device.
"""
import copy


def test_renders_without_errors(render_candidate):
    output = render_candidate()
    assert output.strip() != ""


def test_banner_is_rendered(render_candidate):
    output = render_candidate()
    assert "banner motd ^C" in output
    assert "Authorized access only" in output


def test_ntp_servers_and_prefer_flag(render_candidate):
    output = render_candidate()
    assert "ntp server 10.0.0.10 prefer" in output
    assert "ntp server 10.0.0.11" in output
    # the non-preferred server must NOT carry the "prefer" keyword
    assert "ntp server 10.0.0.11 prefer" not in output
    assert "ntp source Loopback0" in output


def test_snmp_config(render_candidate):
    output = render_candidate()
    assert "snmp-server community public-ro RO" in output
    assert "snmp-server location HQ-DC1" in output
    assert "snmp-server contact netops@example.com" in output
    assert "snmp-server host 10.0.0.30 version 2c trap-community" in output


def test_syslog_config(render_candidate):
    output = render_candidate()
    assert "logging host 10.0.0.20" in output
    assert "logging host 10.0.0.21" in output
    assert "logging trap informational" in output
    assert "logging facility local7" in output
    assert "logging buffered 16384" in output
    assert "logging source-interface Loopback0" in output


def test_optional_source_interface_can_be_omitted(jinja_env, baseline_data):
    data = copy.deepcopy(baseline_data)
    del data["baseline"]["ntp"]["source_interface"]
    del data["baseline"]["syslog"]["source_interface"]

    template = jinja_env.get_template("baseline_config.j2")
    output = template.render(
        **data, inventory_hostname="test-sw01", run_timestamp="20250101_000000"
    )

    assert "ntp source" not in output
    assert "logging source-interface" not in output
    # the rest of the config must still render fine
    assert "ntp server 10.0.0.10 prefer" in output


def test_multiple_devices_render_identical_baseline(render_candidate):
    # The baseline is common to every device: rendering for two different
    # hostnames must produce identical config except for the header.
    sw01 = render_candidate(hostname="test-sw01")
    sw02 = render_candidate(hostname="test-sw02")

    def strip_header(cfg):
        return "\n".join(line for line in cfg.splitlines() if not line.startswith("! Device"))

    assert strip_header(sw01) == strip_header(sw02)
