.PHONY: install lint syntax-check test e2e ci precheck dry-run deploy validate postcheck pipeline

LIMIT ?= network_test

install:
	pip install "ansible-core>=2.15,<2.20" ansible-lint yamllint paramiko
	pip install -r tests/mock_device/requirements.txt
	ansible-galaxy collection install -r requirements.yml

lint:
	yamllint .
	ansible-lint playbooks roles

syntax-check:
	ansible-playbook -i inventory/hosts.yml playbooks/precheck.yml --syntax-check
	ansible-playbook -i inventory/hosts.yml playbooks/dry_run.yml --syntax-check
	ansible-playbook -i inventory/hosts.yml playbooks/deploy.yml --syntax-check
	ansible-playbook -i inventory/hosts.yml playbooks/validate.yml --syntax-check
	ansible-playbook -i inventory/hosts.yml playbooks/postcheck.yml --syntax-check

# Runs the real playbooks end-to-end (real SSH, real network_cli
# connection, real cisco.ios plugins) against a local mock IOS-XE SSH
# device - no lab or real device needed. See tests/mock_device/. This
# is the only test layer in this repo: the baseline config is rendered
# by Jinja2 embedded directly in roles/network_baseline/tasks/render.yml,
# so proving it works means actually running the playbooks with Ansible,
# not rendering a standalone template file.
e2e:
	bash tests/mock_device/run_e2e.sh

# `test` is an alias for `e2e` - kept so `make test` still does "run the
# tests" even though there's no separate unit-test layer anymore.
test: e2e

# Everything the CI pipeline runs, in one shot.
ci: lint syntax-check e2e

# The 5-stage deploy pipeline, one playbook per stage. Each is safe to
# run alone; `pipeline` below chains all 5 against a real/lab device.
precheck:
	ansible-playbook playbooks/precheck.yml --limit $(LIMIT) --ask-vault-pass

dry-run:
	ansible-playbook playbooks/dry_run.yml --diff --limit $(LIMIT) --ask-vault-pass

deploy:
	ansible-playbook playbooks/deploy.yml --diff --limit $(LIMIT) --ask-vault-pass

validate:
	ansible-playbook playbooks/validate.yml --limit $(LIMIT) --ask-vault-pass

postcheck:
	ansible-playbook playbooks/postcheck.yml --limit $(LIMIT) --ask-vault-pass

# Runs the full pipeline in order against a real/lab device, stopping at
# the first stage that fails (make's default behavior for prerequisites) -
# so a drifted device fails at precheck and never reaches deploy, and a
# deploy that didn't actually take effect fails at validate/postcheck.
# To push past a precheck failure and see the plan anyway, run
# playbooks/precheck.yml directly with -e network_baseline_fail_on_drift=false
# (see precheck.yml's own header comment) instead of `make precheck`.
pipeline: precheck dry-run deploy validate postcheck
