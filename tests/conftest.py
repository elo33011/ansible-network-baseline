import pathlib

import pytest
import yaml
from jinja2 import Environment, FileSystemLoader

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMPLATES_DIR = REPO_ROOT / "roles" / "network_baseline" / "templates"
FIXTURES_DIR = pathlib.Path(__file__).resolve().parent / "fixtures"


@pytest.fixture
def baseline_data():
    with open(FIXTURES_DIR / "sample_baseline.yml") as f:
        return yaml.safe_load(f)


@pytest.fixture
def jinja_env():
    # trim_blocks / keep_trailing_newline mirror Ansible's own template
    # lookup/module defaults so what pytest renders matches what the
    # playbook would actually render.
    return Environment(
        loader=FileSystemLoader(str(TEMPLATES_DIR)),
        trim_blocks=True,
        keep_trailing_newline=True,
    )


@pytest.fixture
def render_candidate(jinja_env, baseline_data):
    def _render(hostname="test-sw01", run_timestamp="20250101_000000", **overrides):
        context = {**baseline_data, "inventory_hostname": hostname, "run_timestamp": run_timestamp}
        context.update(overrides)
        template = jinja_env.get_template("baseline_config.j2")
        return template.render(**context)

    return _render
