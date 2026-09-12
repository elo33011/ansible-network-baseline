#!/usr/bin/env bash
#
# Runs the real playbooks (playbooks/check_drift.yml,
# playbooks/deploy_baseline.yml) end-to-end - real SSH, real
# ansible.netcommon network_cli connection, real cisco.ios plugins -
# against the local mock IOS-XE SSH server (mock_ios_ssh_server.py),
# and asserts the drift -> dry-run -> apply -> clean sequence actually
# behaves correctly. Exits non-zero on any unexpected result, so this
# can gate the CI pipeline (see ../../../.github/workflows/ansible-network-baseline-ci.yml).
#
# Usage: tests/mock_device/run_e2e.sh   (run from the project root, or anywhere - paths are self-relative)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PORT=8022
READY_FILE="$(mktemp)"
SERVER_LOG="$(mktemp)"
SERVER_PID=""

cleanup() {
  if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
  rm -f "${READY_FILE}"
  rm -rf "${PROJECT_DIR}"/reports/{rendered,drift,running-config-backup}/*.{cfg,txt} 2>/dev/null || true
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; echo "--- server log ---" >&2; cat "${SERVER_LOG}" >&2 || true; exit 1; }

echo "== starting mock IOS-XE SSH server on 127.0.0.1:${PORT} =="
rm -f "${READY_FILE}"
python3 "${SCRIPT_DIR}/mock_ios_ssh_server.py" \
  --port "${PORT}" \
  --seed "${SCRIPT_DIR}/seed_running_config_drift.txt" \
  --ready-file "${READY_FILE}" \
  > "${SERVER_LOG}" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  [[ -s "${READY_FILE}" ]] && break
  sleep 0.2
done
[[ -s "${READY_FILE}" ]] || fail "mock server never became ready"

cd "${PROJECT_DIR}"

echo "== step 1/4: check_drift.yml against a drifted device (expect drift found, non-zero exit) =="
set +e
OUT1="$(ansible-playbook playbooks/check_drift.yml --limit network_mock 2>&1)"
RC1=$?
set -e
echo "${OUT1}" | tail -20
[[ ${RC1} -ne 0 ]] || fail "check_drift.yml exited 0 against a drifted device (expected non-zero)"
echo "${OUT1}" | grep -q "Baseline drift detected" || fail "check_drift.yml did not report drift"
pass "drift correctly detected and playbook failed as designed"

echo "== step 2/4: deploy_baseline.yml --check --diff (dry run, expect no device change) =="
OUT2="$(ansible-playbook playbooks/deploy_baseline.yml --check --diff --limit network_mock 2>&1)"
echo "${OUT2}" | tail -20
echo "${OUT2}" | grep -q "would change" || fail "dry run did not report 'would change'"
OUT2B="$(ansible-playbook playbooks/check_drift.yml --limit network_mock -e network_baseline_fail_on_drift=false 2>&1)"
echo "${OUT2B}" | grep -q "line(s) out of baseline" || fail "device was modified by a --check dry run"
pass "dry run reported the change but left the device untouched"

echo "== step 3/4: deploy_baseline.yml (real apply) =="
OUT3="$(ansible-playbook playbooks/deploy_baseline.yml --diff --limit network_mock 2>&1)"
echo "${OUT3}" | tail -20
echo "${OUT3}" | grep -q "mock-sw01: changed" || fail "apply did not report a change"
pass "apply pushed the baseline to the device"

echo "== step 4/4: check_drift.yml again (expect clean, zero exit) =="
set +e
OUT4="$(ansible-playbook playbooks/check_drift.yml --limit network_mock 2>&1)"
RC4=$?
set -e
echo "${OUT4}" | tail -20
[[ ${RC4} -eq 0 ]] || fail "check_drift.yml still reports drift after a real apply"
echo "${OUT4}" | grep -q "no drift - matches baseline" || fail "check_drift.yml did not report a clean device"
pass "device matches baseline after apply - full drift -> dry-run -> apply -> clean cycle verified end-to-end"

echo
echo "ALL END-TO-END CHECKS PASSED"
