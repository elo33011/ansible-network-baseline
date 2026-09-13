.PHONY: install lint syntax-check test e2e ci check-drift deploy-dry-run deploy

LIMIT ?= network_test

install:
	pip install "ansible-core>=2.15,<2.20" ansible-lint yamllint paramiko
	pip install -r tests/mock_device/requirements.txt
	ansible-galaxy collection install -r requirements.yml

lint:
	yamllint .
	ansible-lint playbooks roles

syntax-check:
	ansible-playbook -i inventory/hosts.yml playbooks/check_drift.yml --syntax-check
	ansible-playbook -i inventory/hosts.yml playbooks/deploy_baseline.yml --syntax-check

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

check-drift:
	ansible-playbook playbooks/check_drift.yml --limit $(LIMIT) --ask-vault-pass

deploy-dry-run:
	ansible-playbook playbooks/deploy_baseline.yml --check --diff --limit $(LIMIT) --ask-vault-pass

deploy:
	ansible-playbook playbooks/deploy_baseline.yml --diff --limit $(LIMIT) --ask-vault-pass
