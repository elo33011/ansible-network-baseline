# Ansible Network Baseline

A demo Ansible project for managing **baseline configuration** — the
settings that are common to every network device (banner, NTP, SNMP,
syslog) — from a single YAML data model, deployed through a 5-stage
pipeline (precheck, dry run, deploy, validate, postcheck), with a CI
pipeline that develops and tests the playbooks before they're ever used
to deploy.

Example config is Cisco IOS syntax (`cisco.ios` / `network_cli`), but the
push/diff mechanism (`ansible.netcommon.cli_config`) is vendor-neutral —
see [Adapting to other vendors](#adapting-to-other-vendors).

## How the pieces fit together

```
inventory/group_vars/all/baseline.yml (data model, source of truth)
        |
        v
roles/network_baseline/tasks/render.yml  (Jinja2 embedded in the tasks:
        |                                 banner / ntp / snmp / syslog)
        v
candidate config (rendered per device)
        |
        v
   precheck  -->  dry_run  -->  deploy  -->  validate  -->  postcheck
  (blocks if      (shows       (pushes      (fails if      (fails if
   drift found)    the plan)    the diff)    drift remains)  drift remains,
                                                              + audit snapshot)
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

- **Jinja2, embedded in the tasks** — `roles/network_baseline/tasks/render.yml`
  There are no standalone `.j2` template files. Each baseline domain
  (banner, NTP, SNMP, syslog) is its own `set_fact` task whose value is a
  literal Jinja2 block (loops, `{% if %}`s and all) that Ansible renders
  the same way it would a template file — the four blocks are then
  combined into the full candidate config by one more `set_fact`. This
  is deliberate: the Jinja2 only exists inside real Ansible tasks, so
  proving it renders correctly means actually running the playbook with
  Ansible (see [Develop and test in the pipeline before deploying](#develop-and-test-in-the-pipeline-before-deploying)),
  not rendering a template file in isolation.

- **Role** — `roles/network_baseline/`
  `tasks/render.yml` renders the candidate config from the data model.
  `tasks/check_only.yml` compares it against the running-config and
  reports drift **without ever changing anything** — `check_mode: true`
  is hard-coded there, regardless of how the playbook is invoked; it's
  shared by the precheck/dry_run/validate/postcheck stages (see below),
  parameterized by whether finding drift should fail the playbook.
  `tasks/apply.yml` does the same comparison but pushes only the
  drifted lines — used only by the deploy stage.
  `tasks/save_audit_snapshot.yml` captures a final running-config
  snapshot — used only by the postcheck stage.

- **Playbooks — the 5-stage pipeline** — `playbooks/`
  Each stage is its own playbook, so each can be run, scheduled, or
  gated independently:

  | Stage | Playbook | Changes a device? | Fails on drift? |
  | --- | --- | --- | --- |
  | 1. Precheck | `precheck.yml` | No | Yes — blocks before anything is attempted |
  | 2. Dry run | `dry_run.yml` | No | Never — showing the plan is the point |
  | 3. Deploy | `deploy.yml` | **Yes** | n/a — this is the stage that pushes |
  | 4. Validate | `validate.yml` | No | Yes — proves the deploy actually took effect |
  | 5. Postcheck | `postcheck.yml` | No | Yes — plus writes the audit snapshot |

## Why drift is checked before every change

`ansible.netcommon.cli_config` always fetches the device's *actual*
running-config itself and diffs the rendered candidate against it (not
just "what Ansible pushed last time"), computing only the lines that
differ. That means:

- A config change made directly on the device (console/CLI, outside
  Ansible) is caught as drift the next time a stage runs — the report
  shows exactly which lines are out of compliance.
- Only the drifted lines are ever pushed — a device already at baseline
  gets a no-op `deploy.yml` run.
- `precheck.yml` lets you *see* that drift and decide whether to
  investigate it or proceed past it, before anything is changed;
  `validate.yml`/`postcheck.yml` turn the same comparison around after
  `deploy.yml` runs, to prove the push actually worked rather than just
  assuming it did because the command didn't error.

Every run also writes an audit trail:

- `reports/rendered/<device>_<timestamp>.cfg` — the full config generated
  from the data model (what the device *should* look like).
- `reports/drift/<device>_<stage>_<timestamp>.txt` — which lines
  differed at that stage, and whether they were pushed.
- `reports/running-config-backup/<device>_<timestamp>.cfg` — the
  device's running-config as it was immediately before a real change
  (written by `deploy.yml` only).
- `reports/postcheck/<device>_<timestamp>.cfg` — the device's full
  running-config immediately after a confirmed-compliant `postcheck.yml`
  run, as a permanent sign-off record for the change.

## Develop and test in the pipeline before deploying

This is the core workflow the repo is built around: **playbooks are
linted, syntax-checked, and run end-to-end against a mock device on
every push/PR, using only GitHub-hosted runners — no lab or real device
required** — before anyone runs the deploy workflow against actual
hardware.

`.github/workflows/ci.yml` runs on every push
and pull request that touches this project:

1. **lint** — `yamllint` + `ansible-lint` (currently passes at the
   `production` profile) against the playbooks and role.
2. **syntax-check** — `ansible-playbook --syntax-check` on all 5
   pipeline playbooks, with the real collections installed, catching
   bad task structure, undefined module names, etc.
3. **e2e-mock-device** — runs all 5 pipeline playbooks for real: real
   SSH, real `ansible.netcommon` `network_cli` connection, real
   `cisco.ios` cliconf/terminal plugins, real
   `ansible.netcommon.cli_config` module — against
   `tests/mock_device/mock_ios_ssh_server.py`, a small SSH server that
   speaks just enough real Cisco IOS CLI (terminal setup,
   `enable`/privilege escalation, `show running-config`, `configure
   terminal` line pushes, and the special `banner ... @` push path) to
   be driven exactly like a real device would be, without needing a lab
   or a reachable device. `tests/mock_device/run_e2e.sh` seeds it with
   a drifted config (`tests/mock_device/seed_running_config_drift.txt`)
   and asserts each stage in order: `precheck.yml` finds the drift and
   exits non-zero -> `dry_run.yml` reports what would change and
   leaves the device untouched -> `deploy.yml` applies it for real ->
   `validate.yml` confirms clean -> `postcheck.yml` confirms clean and
   writes the audit snapshot. This is the *only* test layer in this
   repo — there's no separate fast/no-Ansible unit-test step, because
   the Jinja2 that renders the config lives inside the tasks themselves
   (see [How the pieces fit together](#how-the-pieces-fit-together)),
   so there's nothing template-shaped left to test in isolation from
   Ansible. It runs entirely over loopback, so it needs nothing beyond
   a GitHub-hosted runner.

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

Only after that pipeline is green does `.github/workflows/deploy.yml`
come into play — a separate, manually-triggered (`workflow_dispatch`)
workflow that always runs precheck and dry_run (read-only), and only
runs deploy/validate/postcheck when the "apply" input is checked.
Protect `main` with a branch-protection rule requiring the CI workflow
to pass, so a broken playbook can never reach the deploy stage.

Like CI, `deploy.yml` runs on a plain GitHub-hosted runner
(`ubuntu-latest`) — against the same mock IOS-XE SSH server CI uses, for
the same reason: `ansible.netcommon.cli_config` connects directly over
SSH, and a GitHub-hosted runner has no route to a real device's private
management IP, only to this loopback mock. That's what makes it possible
to actually click "Run workflow" and watch a real 5-stage deploy happen
with zero infrastructure — no self-hosted runner, no vault, no lab.

The intended promotion path for this demo:

```
PR opened
   -> CI (lint, syntax-check,
      real end-to-end run of all 5 stages against the mock IOS-XE device)
   -> merge to main
   -> Deploy workflow, apply=false  (precheck + dry_run against the mock device)
   -> Deploy workflow, apply=true   (all 5 stages against the mock device)
```

To deploy to *real* devices on a private network instead, see
[Deploying to real devices](#deploying-to-real-devices) below — that
needs a self-hosted runner, since a GitHub-hosted one cannot reach a
private management IP no matter what.

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

- `make e2e` (or `make pipeline LIMIT=network_mock`) — runs the full
  5-stage cycle against the local mock IOS-XE SSH server (see
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

Run the pipeline one stage at a time, in order:

```bash
# 1. Precheck - read-only, fails (blocks) if drift is already present
ansible-playbook playbooks/precheck.yml --limit network_test --ask-vault-pass

# 2. Dry run - read-only, shows exactly what deploy.yml would change
ansible-playbook playbooks/dry_run.yml --diff --limit network_test --ask-vault-pass

# 3. Deploy - pushes only the lines that differ
ansible-playbook playbooks/deploy.yml --diff --limit network_test --ask-vault-pass

# 4. Validate - read-only, fails if drift remains after deploy
ansible-playbook playbooks/validate.yml --limit network_test --ask-vault-pass

# 5. Postcheck - read-only, same gate as validate, plus records the audit snapshot
ansible-playbook playbooks/postcheck.yml --limit network_test --ask-vault-pass
```

Or all 5 in order with `make pipeline LIMIT=network_test` (stops at the
first stage that fails, so a drifted device never reaches `deploy.yml`
without a human first re-running `precheck.yml` with
`-e network_baseline_fail_on_drift=false` to look past it deliberately).

Limit any stage to one device:

```bash
ansible-playbook playbooks/deploy.yml --diff --ask-vault-pass --limit test-sw01
```

## Running from GitHub Actions

See [Develop and test in the pipeline before deploying](#develop-and-test-in-the-pipeline-before-deploying)
above for the full flow. `.github/workflows/deploy.yml` runs on a plain
GitHub-hosted runner with no setup: go to Actions -> Deploy -> Run
workflow. Leave `apply` unchecked for precheck + dry run against the
mock device (no changes), or check it to run all 5 stages against it.
The workflow always uploads the rendered configs, drift reports, and
any postcheck audit snapshot as a build artifact either way.

## Deploying to real devices

Everything above targets the mock IOS-XE device so the whole pipeline —
CI *and* deploy — works with zero infrastructure. To point this at real
devices on a private network instead:

1. Edit `inventory/hosts.yml`'s `network_test`/`network_prod` groups to
   describe your real devices, and `inventory/group_vars/all/baseline.yml`
   to match your org's standard (see [Setup](#setup)).

2. Create the vaulted credentials file:

   ```bash
   cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
   ansible-vault encrypt inventory/group_vars/all/vault.yml
   # then edit with: ansible-vault edit inventory/group_vars/all/vault.yml
   ```

3. Run locally against them with `--limit network_test`/`network_prod`
   (see [Usage](#usage)) — this works from any machine that can already
   reach the devices' management IPs.

4. To also run this from GitHub Actions, `ansible.netcommon.cli_config`
   still needs direct SSH reachability, which a GitHub-hosted runner does
   not have to a private network — set up a self-hosted runner instead:
   [`ci/setup-self-hosted-runner.sh`](ci/setup-self-hosted-runner.sh)
   installs prerequisites, downloads the latest `actions/runner`,
   registers it with the labels `self-hosted,network,linux`, and runs it
   as a systemd service under a dedicated unprivileged `ghrunner` user:

   ```bash
   sudo ./ci/setup-self-hosted-runner.sh \
     https://github.com/elo33011/ansible-network-baseline \
     <registration-token> \
     <runner-name>   # optional
   ```

   Get `<registration-token>` from this repo's Settings -> Actions ->
   Runners -> New self-hosted runner (it's short-lived, ~1 hour - copy
   it and run the script right away). See the script's own comments for
   the full setup and security notes (repo-scoped runner,
   `workflow_dispatch` only, never on `pull_request` from forks).

5. Adapt `.github/workflows/deploy.yml` for that runner: change
   `runs-on: ubuntu-latest` to `runs-on: [self-hosted, network]`, drop
   the mock-server step, add a `limit` input
   (`network_test`/`network_prod`/a hostname) in place of the hard-coded
   `network_mock` on each of the 5 `ansible-playbook` steps, and add
   steps to write/remove the vault file from secrets before/after them:

   ```yaml
   - name: Write vault credentials
     run: |
       echo "${{ secrets.ANSIBLE_VAULT_PASSWORD }}" > .vault_pass
       echo "${{ secrets.ANSIBLE_VAULT_YML_B64 }}" | base64 -d > inventory/group_vars/all/vault.yml
       chmod 600 .vault_pass inventory/group_vars/all/vault.yml
   # ...add --vault-password-file .vault_pass to each ansible-playbook command...
   - name: Remove vault credentials
     if: always()
     run: rm -f .vault_pass inventory/group_vars/all/vault.yml
   ```

   Required repo (or environment) secrets for that variant:

   - `ANSIBLE_VAULT_PASSWORD` — the `ansible-vault` password.
   - `ANSIBLE_VAULT_YML_B64` — base64 of your encrypted
     `inventory/group_vars/all/vault.yml`:
     ```bash
     ansible-vault encrypt inventory/group_vars/all/vault.yml   # if not already encrypted
     base64 -w0 inventory/group_vars/all/vault.yml
     ```

   For real changes, gate the `network-production` GitHub Environment
   with required reviewers (Settings -> Environments) so an
   `apply=true` run against `network_prod` needs a human approval
   before the deploy stage touches a device.

## Adding a new baseline setting

1. Add the value(s) to `inventory/group_vars/all/baseline.yml` under `baseline:`.
2. Add (or extend) the relevant `set_fact` block in
   `roles/network_baseline/tasks/render.yml` (there's one per domain:
   banner/ntp/snmp/syslog), and reference it from the "Combine blocks"
   task if it's a new domain.
3. If you want it covered by the mock-device test, add the expected
   line(s) to `tests/mock_device/seed_running_config_drift.txt` (as
   drift, i.e. the *old* value) so `tests/mock_device/run_e2e.sh`
   exercises it.
4. Push — the CI pipeline lints, syntax-checks, and actually runs all 5
   stages end-to-end against the mock device before it's usable for a
   real deploy.

## Adding a new device

Add a host entry under `network_test` or `network_prod` in
`inventory/hosts.yml` — no task or playbook changes needed; the
baseline applies uniformly to every device in
`network_baseline_devices`.

## Adapting to other vendors

`ansible.netcommon.cli_config` and `cli_command` work over any
`network_cli`-capable platform, not just IOS. To target Arista EOS, Cisco
NX-OS, etc.:

1. Add the vendor's collection to `requirements.yml` (e.g. `arista.eos`,
   `cisco.nxos`).
2. Set `ansible_network_os` in `inventory/hosts.yml` accordingly (e.g.
   `arista.eos.eos`).
3. Adjust the command syntax in the Jinja2 blocks in
   `roles/network_baseline/tasks/render.yml` to match that vendor's CLI,
   and swap `write memory` in `roles/network_baseline/tasks/apply.yml`
   for the equivalent save command (e.g. `copy running-config
   startup-config` with a `check_all`/prompt on IOS-XE, or `write` on
   EOS).

## Notes

- `inventory/group_vars/all/vault.yml` and everything under `reports/` is
  git-ignored — never commit real credentials or device configs with
  live IPs/secrets in plaintext.
- `precheck.yml`, `dry_run.yml`, `validate.yml` and `postcheck.yml`
  never change a device no matter what flags they're run with
  (`check_mode: true` is hard-coded in
  `roles/network_baseline/tasks/check_only.yml`, which all four share);
  only `deploy.yml`, run without `--check`, does.
- There's no standalone Jinja2 template file and no separate
  no-Ansible unit-test layer for it — the config-rendering logic lives
  entirely inside `roles/network_baseline/tasks/render.yml`, so the
  `e2e-mock-device` CI job (real `ansible-playbook`, real SSH, against
  the mock device) is the only thing that proves it renders and deploys
  correctly. See [Develop and test in the pipeline before deploying](#develop-and-test-in-the-pipeline-before-deploying).
