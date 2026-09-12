"""
Unit tests for the drift-detection concept used by
roles/network_baseline/tasks/drift_check_forced.yml
(ansible.netcommon.cli_config with diff_against: running).

That module needs a real network_cli-capable device to talk to, which
CI doesn't have. What CAN be tested without one is the underlying idea:
"lines present in the rendered candidate config but absent from the
device's current running-config are drift". These tests exercise exactly
that logic against fixture "running-config" snippets, so a mistake in
the data model or a template (e.g. a value that silently stops
rendering) is caught in CI before it ever reaches check_drift.yml /
deploy_baseline.yml against a real device.
"""
import pathlib

FIXTURES_DIR = pathlib.Path(__file__).resolve().parent / "fixtures"


def _config_lines(text):
    return {
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.strip().startswith("!")
    }


def find_drift(candidate_text, running_text):
    """Lines the baseline requires that the running-config doesn't have."""
    return _config_lines(candidate_text) - _config_lines(running_text)


def test_drift_is_detected_against_a_drifted_device(render_candidate):
    candidate = render_candidate()
    running = (FIXTURES_DIR / "mock_running_config_drift.txt").read_text()

    drift = find_drift(candidate, running)

    assert "ntp server 10.0.0.11" in drift
    assert "snmp-server location HQ-DC1" in drift
    assert "logging host 10.0.0.21" in drift

    # unchanged settings must NOT be reported as drift
    assert "ntp server 10.0.0.10 prefer" not in drift
    assert "snmp-server contact netops@example.com" not in drift
    assert "logging host 10.0.0.20" not in drift


def test_no_drift_against_a_compliant_device(render_candidate):
    candidate = render_candidate()
    running = (FIXTURES_DIR / "mock_running_config_clean.txt").read_text()

    drift = find_drift(candidate, running)

    assert drift == set()
