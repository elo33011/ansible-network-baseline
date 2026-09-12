.PHONY: install lint syntax-check test check-drift deploy-dry-run deploy

LIMIT ?= network_test

install:
	pip install "ansible-core>=2.15,<2.20" ansible-lint yamllint -r tests/requirements-test.txt
	ansible-galaxy collection install -r requirements.yml

lint:
	yamllint .
	ansible-lint playbooks roles

syntax-check:
	ansible-playbook -i inventory/hosts.yml playbooks/check_drift.yml --syntax-check
	ansible-playbook -i inventory/hosts.yml playbooks/deploy_baseline.yml --syntax-check

test:
	pytest tests/ -v

# Everything the CI pipeline runs, in one shot.
ci: lint syntax-check test

check-drift:
	ansible-playbook playbooks/check_drift.yml --limit $(LIMIT) --ask-vault-pass

deploy-dry-run:
	ansible-playbook playbooks/deploy_baseline.yml --check --diff --limit $(LIMIT) --ask-vault-pass

deploy:
	ansible-playbook playbooks/deploy_baseline.yml --diff --limit $(LIMIT) --ask-vault-pass
