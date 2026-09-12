# Ansible Network Baseline

A demo Ansible project for managing **baseline configuration** — the
settings that are common to every network device (banner, NTP, SNMP,
syslog) — from a single YAML data model, with drift detection before any
change is pushed, and a CI pipeline that develops and tests the playbooks
before they're ever used to deploy.

Example config is Cisco IOS syntax (`cisco.ios` / `network_cli`), but the
push/diff mechanism (`ansible.netcommon.cli_config`) is vendor-neutral —
see [Adapting to other vendors](#adapting-to-other-vendors).

## How the pieces fit together

```
inventory/group_vars/all/baseline.yml (data model, source of truth)
        |
        v
roles/network_baseline/templates/*.j2  (banner / ntp / snmp / syslog)
        |
        v
candidate config (rendered per device)
        |
        v
compare against the device's running-config  --> drift report
        |
        v
push ONLY the lines that differ               --> device
```

- **Data model / source of truth** — `inventory/group_vars/all/baseline.yml`
  Everything that defines the organization's baseline standard: the MOTD
  banner text, NTP servers, SNMP contact/location/communities/trap hosts,
  and syslog servers/facility/level. This is the one file people edit
  when the standard changes. Secrets referenced from it (SNMP community
  strings, device credentials) live in an `ansible-vault`-encrypted
  `inventory/group_vars/all/vault.yml`.

- **Network source of truth** — `inventory/hosts.yml`
  Which devices exist, how to reach them, and which environment
  (`network_test` vs `network_prod`) each belongs to.

- **Jinja2 templates** — `roles/network_baseline/templates/`
  One template per baseline domain (`banner.j2`, `ntp.j2`, `snmp.j2`,
  `syslog.j2`), combined by `baseline_config.j2` into the full candidate
  configuration. Splitting them keeps each concern independently
  readable and testable.

- **Role** — `roles/network_baseline/`
  `tasks/render.yml` renders the candidate config from the data model.
  `tasks/drift_check_forced.yml` compares it against the running-config
  and reports drift **without ever changing anything** — `check_mode:
  true` is hard-coded there, regardless of how the playbook is invoked.
  `tasks/apply.yml` does the same comparison but pushes only the drifted
  lines, and respects `--check` for a real dry run.

- **Playbooks** — `playbooks/`
  `check_drift.yml` is the read-only gate: run it anytime to see whether
  any device has drifted from baseline (and, by default, it fails/exits
  non-zero if drift is found, so it doubles as a CI/CD check).
  `deploy_baseline.yml` renders, diffs, and reconciles each device with
  the baseline — dry run with `--check --diff`, apply for real without
  `--check`.

## Why drift is checked before every change

`ansible.netcommon.cli_config` always fetches the device's *actual*
running-config itself and diffs the rendered candidate against it (not
just "what Ansible pushed last time"), computing only the lines that
differ. That means:

- A config change made directly on the device (console/CLI, outside
  Ansible) is caught as drift the next time the playbook runs — the
  drift report shows exactly which lines are out of compliance.
- Only the drifted lines are ever pushed — a device already at baseline
  gets a no-op run.
- `playbooks/check_drift.yml` lets you *see* that drift, and decide
  whether to accept it (re-run deploy) or investigate it, before
  anything is changed.

Every run also writes an audit trail:

- `reports/rendered/<device>_<timestamp>.cfg` — the full config generated
  from the data model (what the device *should* look like).
- `reports/drift/<device>_<timestamp>.txt` — which lines differed and
  whether they were pushed.
- `reports/running-config-backup/<device>_<timestamp>.cfg` — the
  device's running-config as it was immediately before a real change
  (written by `deploy_baseline.yml`'s apply path only).

## Develop and test in the pipeline before deploying

This is the core workflow the repo is built around: **playbooks are
linted, syntax-checked, unit-tested, and run end-to-end against a mock
device on every push/PR, using only GitHub-hosted runners — no lab or
real device required** — before anyone runs the deploy workflow against
actual hardware.

`.github/workflows/ci.yml` runs on every push
and pull request that touches this project:

1. **lint** — `yamllint` + `ansible-lint` (currently passes at the
   `production` profile) against the playbooks and role.
2. **syntax-check** — `ansible-playbook --syntax-check` on both
   playbooks, with the real collections installed, catching bad task
   structure, undefined module names, etc.
3. **unit-test-templates** — `pytest` renders the actual Jinja2 templates
   in `roles/network_baseline/templates/` with sample data
   (`tests/fixtures/sample_baseline.yml`) using plain Jinja2 (no Ansible,
   no device) and asserts the generated config lines are correct — see
   `tests/test_templates.py`. A second suite,
   `tests/test_drift_detection.py`, renders the same candidate config and
   diffs it against fixture "running-config" snippets
   (`tests/fixtures/mock_running_config_drift.txt` and
   `..._clean.txt`) to prove the drift-detection *logic* correctly finds
   exactly the lines that were changed underneath it, and finds nothing
   when the device already matches baseline. This is the fast, reliable
   part of "tested via the pipeline" — it runs in under a second and
   needs no network access.

4. **e2e-mock-device** — runs `playbooks/check_drift.yml` and
   `playbooks/deploy_baseline.yml` for real: real SSH, real
   `ansible.netcommon` `network_cli` connection, real `cisco.ios`
   cliconf/terminal plugins, real `ansible.netcommon.cli_config`
   module — against `tests/mock_device/mock_ios_ssh_server.py`, a small
   SSH server that speaks just enough real Cisco IOS CLI (terminal
   setup, `enable`/privilege escalation, `show running-config`,
   `configure terminal` line pushes, and the special `banner ... @`
   push path) to be driven exactly like a real device would be, without
   needing a lab or a reachable device. `tests/mock_device/run_e2e.sh`
   seeds it with a drifted config
   (`tests/mock_device/seed_running_config_drift.txt`) and asserts the
   full cycle: `check_drift.yml` finds the drift and exits non-zero ->
   `deploy_baseline.yml --check --diff` reports what would change and
   leaves the device untouched -> `deploy_baseline.yml` applies it for
   real -> `check_drift.yml` reports clean. This is what "tested via
   the pipeline" means for the playbooks themselves, not just their
   templates — and it runs entirely over loopback, so it needs nothing
   beyond a GitHub-hosted runner.

   *(Why a mock device instead of Cisco's DevNet Always-On IOS-XE
   sandbox: this repo was built in a sandboxed environment with no
   outbound access to arbitrary hosts, so reaching that sandbox — or
   any real device — wasn't possible from there. The mock server was
   built by reading `cisco.ios`'s actual cliconf/terminal plugin source
   to replicate the exact command sequence a real IOS-XE device would
   see, so the same playbooks run unmodified against a real device or
   Cisco's sandbox — just point `inventory/hosts.yml` at it, see
   [Setup](#setup).)*

Run the same checks locally with `make ci` (or `make lint` / `make
syntax-check` / `make test` / `make e2e` individually).

Only after that pipeline is green does
`.github/workflows/deploy.yml` come into play —
a separate, manually-triggered (`workflow_dispatch`) workflow that runs
on a self-hosted runner with real network access, and always runs the
read-only drift check, then a dry run, before an optional real apply.
Protect `main` with a branch-protection rule requiring the CI workflow
to pass, so a broken playbook can never reach the deploy stage.

The intended promotion path:

```
PR opened
   -> CI (lint, syntax-check, unit tests,
      real end-to-end run against the mock IOS-XE device)
   -> merge to main
   -> Deploy workflow, limit=network_test,  apply=false  (dry run against the lab)
   -> Deploy workflow, limit=network_test,  apply=true   (apply to the lab)
   -> Deploy workflow, limit=network_prod,  apply=false  (dry run against prod)
   -> Deploy workflow, limit=network_prod,  apply=true   (apply to prod, gated by
      the "network-production" GitHub Environment's required reviewers)
```

## Setup

1. Install collections:

   ```bash
   ansible-galaxy collection install -r requirements.yml
   ```

2. Create the vaulted credentials file:

   ```bash
   cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
   ansible-vault encrypt inventory/group_vars/all/vault.yml
   # then edit with: ansible-vault edit inventory/group_vars/all/vault.yml
   ```

3. Edit `inventory/hosts.yml` to describe your real devices (grouped
   under `network_test` / `network_prod`), and
   `inventory/group_vars/all/baseline.yml` to match your org's standard.

To try the playbooks against something reachable before you have real
devices wired up, either:

- `make e2e` — runs the full drift -> dry-run -> apply -> clean cycle
  against the local mock IOS-XE SSH server (see
  [Develop and test in the pipeline before deploying](#develop-and-test-in-the-pipeline-before-deploying)),
  or start it yourself with
  `python3 tests/mock_device/mock_ios_ssh_server.py --seed tests/mock_device/seed_running_config_drift.txt`
  and run any command from [Usage](#usage) below with `--limit
  network_mock` (no vault needed — its connection vars are inline in
  `inventory/hosts.yml`'s `network_mock` group); or
- point a host in `inventory/hosts.yml` at a real reachable device,
  e.g. Cisco's DevNet Always-On IOS-XE sandbox
  (`sandbox-iosxe-latest-1.cisco.com`) if your network allows outbound
  access to it — the playbooks are unmodified either way, only
  `ansible_host`/credentials differ.

## Usage

Read-only drift check (safe anytime, no changes, exits non-zero if drift
is found):

```bash
ansible-playbook playbooks/check_drift.yml --limit network_test --ask-vault-pass
```

Dry run of a real deploy (shows the exact config lines that would be
pushed, makes no changes):

```bash
ansible-playbook playbooks/deploy_baseline.yml --check --diff --limit network_test --ask-vault-pass
```

Deploy for real:

```bash
ansible-playbook playbooks/deploy_baseline.yml --diff --limit network_test --ask-vault-pass
```

Limit to one device:

```bash
ansible-playbook playbooks/deploy_baseline.yml --diff --ask-vault-pass --limit test-sw01
```

## Running from GitHub Actions

See [Develop and test in the pipeline before deploying](#develop-and-test-in-the-pipeline-before-deploying)
above for the full flow. The deploy workflow (`.github/workflows/deploy.yml`)
needs a self-hosted runner reachable on your management network —
[`ci/setup-self-hosted-runner.sh`](ci/setup-self-hosted-runner.sh) installs
prerequisites, downloads the latest `actions/runner`, registers it with
the labels the workflow expects (`self-hosted,network,linux`), and runs
it as a systemd service under a dedicated unprivileged `ghrunner` user:

```bash
sudo ./ci/setup-self-hosted-runner.sh \
  https://github.com/elo33011/ansible-network-baseline \
  <registration-token> \
  <runner-name>   # optional
```

Get `<registration-token>` from this repo's Settings -> Actions ->
Runners -> New self-hosted runner (it's short-lived, ~1 hour - copy it
and run the script right away). See the script's own comments for the
full setup and security notes (repo-scoped runner, `workflow_dispatch`
only, never on `pull_request` from forks).

Required repo (or environment) secrets for the deploy workflow:

- `ANSIBLE_VAULT_PASSWORD` — the `ansible-vault` password.
- `ANSIBLE_VAULT_YML_B64` — base64 of your encrypted
  `inventory/group_vars/all/vault.yml`:
  ```bash
  ansible-vault encrypt inventory/group_vars/all/vault.yml   # if not already encrypted
  base64 -w0 inventory/group_vars/all/vault.yml
  ```

For real changes, gate the `network-production` GitHub Environment with
required reviewers (Settings -> Environments) so an `apply=true` run
against `network_prod` needs a human approval before it touches a
device. The workflow always uploads the rendered configs and drift
reports as a build artifact, whether or not it applies.

## Adding a new baseline setting

1. Add the value(s) to `inventory/group_vars/all/baseline.yml` under `baseline:`.
2. Add (or extend) the relevant template in
   `roles/network_baseline/templates/` and `{% include %}` it from
   `baseline_config.j2` if it's new.
3. Add a case to `tests/test_templates.py` asserting the new line(s)
   render correctly, and to `tests/fixtures/mock_running_config_*.txt`
   / `tests/test_drift_detection.py` if you want drift-detection
   coverage for it.
4. Push — the CI pipeline lints, syntax-checks and tests it before it's
   usable for a real deploy.

## Adding a new device

Add a host entry under `network_test` or `network_prod` in
`inventory/hosts.yml` — no template, role, or playbook changes needed;
the baseline applies uniformly to every device in
`network_baseline_devices`.

## Adapting to other vendors

`ansible.netcommon.cli_config` and `cli_command` work over any
`network_cli`-capable platform, not just IOS. To target Arista EOS, Cisco
NX-OS, etc.:

1. Add the vendor's collection to `requirements.yml` (e.g. `arista.eos`,
   `cisco.nxos`).
2. Set `ansible_network_os` in `inventory/hosts.yml` accordingly (e.g.
   `arista.eos.eos`).
3. Adjust the command syntax in `roles/network_baseline/templates/*.j2`
   to match that vendor's CLI, and swap `write memory` in
   `roles/network_baseline/tasks/apply.yml` for the equivalent save
   command (e.g. `copy running-config startup-config` with a
   `check_all`/prompt on IOS-XE, or `write` on EOS).

## Notes

- `inventory/group_vars/all/vault.yml` and everything under `reports/` is
  git-ignored — never commit real credentials or device configs with
  live IPs/secrets in plaintext.
- `playbooks/check_drift.yml` never changes a device no matter what
  flags it's run with (`check_mode: true` is hard-coded in
  `roles/network_baseline/tasks/drift_check_forced.yml`); only
  `playbooks/deploy_baseline.yml`, run without `--check`, does.
- The CI pipeline's unit tests (`tests/test_templates.py`,
  `tests/test_drift_detection.py`) intentionally don't require Ansible
  or a real device to run — they test the data-model-to-config and
  drift-detection *logic* directly so they're fast and reliable on every
  push. Testing the full playbooks against a real (or lab) device is
  what `check_drift.yml` / `deploy_baseline.yml --check` against
  `network_test` are for.
