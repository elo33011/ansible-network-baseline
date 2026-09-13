#!/usr/bin/env bash
#
# Runs the real 5-stage deploy pipeline (playbooks/precheck.yml,
# dry_run.yml, deploy.yml, validate.yml, postcheck.yml) end-to-end -
# real SSH, real ansible.netcommon network_cli connection, real
# cisco.ios plugins - against the local mock IOS-XE SSH server
# (mock_ios_ssh_server.py), and asserts each stage behaves correctly.
# Exits non-zero on any unexpected result, so this can gate the CI
# pipeline (see ../../.github/workflows/ci.yml).
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
  rm -rf "${PROJECT_DIR}"/reports/{rendered,drift,running-config-backup,postcheck}/*.{cfg,txt} 2>/dev/null || true
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

echo "== stage 1/5: precheck.yml against a drifted device (expect drift found, non-zero exit) =="
set +e
OUT1="$(ansible-playbook playbooks/precheck.yml --limit network_mock 2>&1)"
RC1=$?
set -e
echo "${OUT1}" | tail -20
[[ ${RC1} -ne 0 ]] || fail "precheck.yml exited 0 against a drifted device (expected non-zero)"
echo "${OUT1}" | grep -q "Baseline drift detected" || fail "precheck.yml did not report drift"
pass "precheck correctly blocked on drift"

echo "== stage 2/5: dry_run.yml (expect it reports the change but never fails, and leaves the device untouched) =="
OUT2="$(ansible-playbook playbooks/dry_run.yml --diff --limit network_mock 2>&1)"
echo "${OUT2}" | tail -20
echo "${OUT2}" | grep -q "line(s) out of baseline" || fail "dry_run.yml did not report the drift it would fix"
OUT2B="$(ansible-playbook playbooks/precheck.yml --limit network_mock -e network_baseline_fail_on_drift=false 2>&1)"
echo "${OUT2B}" | grep -q "line(s) out of baseline" || fail "device was modified by dry_run.yml"
pass "dry run reported the change but left the device untouched"

echo "== stage 3/5: deploy.yml (real apply) =="
OUT3="$(ansible-playbook playbooks/deploy.yml --diff --limit network_mock 2>&1)"
echo "${OUT3}" | tail -20
echo "${OUT3}" | grep -q "mock-sw01: changed" || fail "deploy.yml did not report a change"
pass "deploy pushed the baseline to the device"

echo "== stage 4/5: validate.yml (expect clean, zero exit) =="
set +e
OUT4="$(ansible-playbook playbooks/validate.yml --limit network_mock 2>&1)"
RC4=$?
set -e
echo "${OUT4}" | tail -20
[[ ${RC4} -eq 0 ]] || fail "validate.yml still reports drift after deploy.yml"
echo "${OUT4}" | grep -q "no drift - matches baseline" || fail "validate.yml did not report a clean device"
pass "validate confirms the device matches baseline after deploy"

echo "== stage 5/5: postcheck.yml (expect clean, zero exit, and an audit snapshot written) =="
set +e
OUT5="$(ansible-playbook playbooks/postcheck.yml --limit network_mock 2>&1)"
RC5=$?
set -e
echo "${OUT5}" | tail -20
[[ ${RC5} -eq 0 ]] || fail "postcheck.yml reports drift after deploy.yml"
echo "${OUT5}" | grep -q "no drift - matches baseline" || fail "postcheck.yml did not report a clean device"
SNAPSHOT_COUNT=$(find "${PROJECT_DIR}/reports/postcheck" -name '*.cfg' | wc -l)
[[ "${SNAPSHOT_COUNT}" -ge 1 ]] || fail "postcheck.yml did not write an audit snapshot to reports/postcheck/"
grep -q "COMPLIANT - matches baseline" "${PROJECT_DIR}"/reports/postcheck/*.cfg || fail "audit snapshot did not record a COMPLIANT result"
pass "postcheck confirms compliance and records the audit snapshot"

echo
echo "ALL 5 PIPELINE STAGES PASSED END-TO-END"
