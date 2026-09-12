#!/usr/bin/env bash
#
# Installs and registers a GitHub Actions self-hosted runner for the
# deploy workflow, on a Linux host with systemd.
#
# Run this ON THE HOST that will execute the workflow — it must have
# network access (SSH/443) to your devices' management IPs. Do NOT run
# it inside this repo's CI or on a machine that can't reach the devices.
#
# Usage:
#   sudo ./setup-self-hosted-runner.sh <repo-url> <registration-token> [runner-name]
#
# Example:
#   sudo ./setup-self-hosted-runner.sh \
#     https://github.com/elo33011/ansible-network-baseline \
#     AXXXXXXXXXXXXXXXXXXXXXXXXXXXX \
#     netops-runner-01
#
# Where to get <registration-token>:
#   GitHub repo -> Settings -> Actions -> Runners -> New self-hosted runner
#   (or, if you administer the org: Settings -> Actions -> Runners at the
#   org level). The token shown there is short-lived (~1 hour) - copy it
#   and run this script right away.
#
# Labels: this script always adds "self-hosted,network,linux" so it
# matches `runs-on: [self-hosted, network]` in
# .github/workflows/deploy.yml.
#
# Security notes:
#   - Prefer a REPO-level runner over an org-level one — it only picks up
#     jobs from this repository.
#   - Run it as the dedicated, unprivileged "ghrunner" user this script
#     creates, not as root and not as your own login user.
#   - Only wire this runner to workflows triggered by workflow_dispatch
#     (as deploy.yml is). Never let a self-hosted runner pick up
#     workflows triggered by pull_request from forks - an
#     attacker-controlled PR would get arbitrary code execution on a
#     machine that can reach your devices.

set -euo pipefail

REPO_URL="${1:?Usage: $0 <repo-url> <registration-token> [runner-name]}"
REG_TOKEN="${2:?Usage: $0 <repo-url> <registration-token> [runner-name]}"
RUNNER_NAME="${3:-$(hostname)-netops-runner}"
RUNNER_USER="ghrunner"
RUNNER_HOME="/opt/actions-runner"
LABELS="self-hosted,network,linux"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root (sudo) - it creates a system user and a systemd service." >&2
  exit 1
fi

echo "==> Installing OS prerequisites"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y curl tar jq git python3 python3-pip python3-venv openssh-client ca-certificates
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl tar jq git python3 python3-pip openssh-clients ca-certificates
else
  echo "Unsupported package manager - install curl, tar, jq, git, python3, python3-pip, openssh-client manually and re-run." >&2
  exit 1
fi

echo "==> Creating dedicated service user '${RUNNER_USER}'"
if ! id -u "${RUNNER_USER}" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "${RUNNER_HOME}" --shell /usr/sbin/nologin "${RUNNER_USER}"
fi
mkdir -p "${RUNNER_HOME}"
chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_HOME}"

echo "==> Resolving latest actions/runner release"
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64) RUNNER_ARCH="x64" ;;
  aarch64|arm64) RUNNER_ARCH="arm64" ;;
  *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;;
esac
LATEST_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
TARBALL="actions-runner-linux-${RUNNER_ARCH}-${LATEST_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${LATEST_VERSION}/${TARBALL}"

echo "==> Downloading ${DOWNLOAD_URL}"
sudo -u "${RUNNER_USER}" curl -fsSL -o "${RUNNER_HOME}/${TARBALL}" "${DOWNLOAD_URL}"
sudo -u "${RUNNER_USER}" tar xzf "${RUNNER_HOME}/${TARBALL}" -C "${RUNNER_HOME}"
rm -f "${RUNNER_HOME}/${TARBALL}"

echo "==> Configuring the runner (labels: ${LABELS})"
sudo -u "${RUNNER_USER}" "${RUNNER_HOME}/config.sh" \
  --unattended \
  --url "${REPO_URL}" \
  --token "${REG_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${LABELS}" \
  --work "_work"

echo "==> Installing and starting the systemd service (runs as ${RUNNER_USER})"
cd "${RUNNER_HOME}"
./svc.sh install "${RUNNER_USER}"
./svc.sh start

echo "==> Done. Check status with: ./svc.sh status  (run from ${RUNNER_HOME})"
echo "==> Verify it shows up: GitHub repo -> Settings -> Actions -> Runners"
