.PHONY: install lint syntax-check test e2e ci check-drift deploy-dry-run deploy

LIMIT ?= network_test

install:
	pip install "ansible-core>=2.15,<2.20" ansible-lint yamllint paramiko -r tests/requirements-test.txt
	ansible-galaxy collection install -r requirements.yml

lint:
	yamllint .
	ansible-lint playbooks roles

syntax-check:
	ansible-playbook -i inventory/hosts.yml playbooks/check_drift.yml --syntax-check
	ansible-playbook -i inventory/hosts.yml playbooks/deploy_baseline.yml --syntax-check

test:
	pytest tests/ -v

# Runs the real playbooks end-to-end (real SSH, real network_cli
# connection, real cisco.ios plugins) against a local mock IOS-XE SSH
# device - no lab or real device needed. See tests/mock_device/.
e2e:
	bash tests/mock_device/run_e2e.sh

# Everything the CI pipeline runs, in one shot.
ci: lint syntax-check test e2e

check-drift:
	ansible-playbook playbooks/check_drift.yml --limit $(LIMIT) --ask-vault-pass

deploy-dry-run:
	ansible-playbook playbooks/deploy_baseline.yml --check --diff --limit $(LIMIT) --ask-vault-pass

deploy:
	ansible-playbook playbooks/deploy_baseline.yml --diff --limit $(LIMIT) --ask-vault-pass
