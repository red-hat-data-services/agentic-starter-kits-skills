---
name: add-integration-tests
description: >-
  Add integration deployment tests (health-check on OpenShift) to an agent in
  the agentic-starter-kits repo. Creates conftest.py, test_deployment.py,
  __init__.py, adds test-integration Makefile target, and updates the CI
  workflow matrix. Use when implementing integration tests, deployment tests,
  or health-check tests for a new agent.
argument-hint: "<agent_path> [JIRA-KEY]"
---
# Add Integration Tests to an Agent

End-to-end workflow for adding integration deployment tests to any standard agent in the agentic-starter-kits repo. Produces per-agent pytest integration tests that build on OpenShift, deploy via Helm, validate the `/health` endpoint, and tear down.

## Boundary: Do NOT modify the agent under test

The agent's source code (`src/`, `main.py`, tool definitions, Dockerfile) is **out of scope** for this workflow. Integration tests observe the agent as-is.

If you discover a bug or deficiency in the agent (e.g., broken health endpoint, missing Makefile targets, build failures):

1. **Do NOT fix it in the agent code.**
2. **Log a Jira bug** under the parent epic of the current ticket.
3. **Document the limitation** in a comment on the Jira ticket.
4. **Continue with the remaining phases** — write the tests against the agent's current behavior.

Adding NEW test-only artifacts under the agent directory IS in scope: `tests/integration/`.

## Input

Arguments: $ARGUMENTS

Parse the arguments to determine:

- **Agent path**: relative to `agents/` (e.g., `langgraph/templates/react_agent`, `crewai/templates/websearch_agent`)
- **Jira key**: optional ticket reference for context

If no agent path is provided, ask the user which agent to add integration tests to.

## Phase 0: Parse Input and Gather Jira Context

**If a Jira key is provided**: Fetch the ticket to extract scope, acceptance criteria, and parent epic for context.

**If no ticket is provided**: Ask the user for the Jira ticket key or confirm that no ticket tracking is needed.

Validate prerequisites:

1. Working directory is the agentic-starter-kits repo root (`AGENTS.md` exists)
2. Agent directory exists at `agents/<agent_path>/`
3. Agent is standard — has `main.py`, `agent.yaml`, and `Makefile`
4. If any are missing, stop and tell the user this workflow does not support non-standard agents

## Phase 1: Investigate the Agent

Gather these facts — the discovered capabilities drive all subsequent phases:

1. **Agent name**: Read `agent.yaml` — extract the `name` field
2. **Existing integration tests**: Check if `tests/integration/test_deployment.py` already exists. If yes, stop and inform the user — no work needed
3. **Makefile targets**: Check if `test-integration`, `build-openshift`, `deploy`, `undeploy` targets exist. If `build-openshift` is missing, stop — the agent cannot be built on-cluster

### Capability discovery

4. **Required env vars**: Read `agent.yaml` `env.required` section AND `.env.example`. Identify every env var the agent needs. Then determine:

   - **`has_extra_env_vars`**: Does the agent require vars beyond `BASE_URL`, `MODEL_ID` (and `API_KEY` which is always optional)? If yes, record the list of extra var names.
   - **`has_infrastructure_deps`**: Do the extra vars indicate pre-provisioned services — databases (`POSTGRES_*`), vector stores (`VECTOR_STORE_*`, `MILVUS_*`), message queues, etc.? If yes, record what kind of infrastructure. This drives the `<AGENT_DESCRIPTION>` in `_write_env_file` error messages (Phase 2) — e.g., "database-backed agent", "RAG agent with vector store".

   Examples of what you might discover:
   - No extra vars → majority pattern (react_agent, crewai/websearch_agent, human_in_the_loop)
   - RAG vars (`EMBEDDING_MODEL`, `VECTOR_STORE_ID`) → extra env vars, infrastructure dep (vector store)
   - DB vars (`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`) → extra env vars, infrastructure dep (database)

5. **Reference template**: Read an existing agent's integration test to ground the patterns:
   - Always read: `agents/langgraph/templates/react_agent/tests/integration/test_deployment.py`
   - If `has_extra_env_vars`: also read `agents/langgraph/templates/agentic_rag/tests/integration/conftest.py` and `agents/langgraph/templates/agentic_rag/tests/integration/test_deployment.py`

   **Note**: When the reference code differs from the templates in Phase 2, the Phase 2 templates take precedence. The reference files are for understanding the overall structure, not for copying import styles or minor details verbatim. In particular, always use `from integration.conftest import cluster_auth, repo_root` (not `import integration.conftest`) — the explicit form is required for pytest fixture discovery and is enforced by the eval criteria.

Record all discovered capabilities — they determine the file structure (Phase 2), CI config (Phase 4), and consistency checks (Phase 5c).

## Phase 2: Create Test Files

### Directory structure

```
agents/<framework>/templates/<agent_name>/tests/integration/
  __init__.py
  conftest.py
  test_deployment.py
```

**If `tests/integration/` already exists**: inspect existing files before creating anything. Preserve any agent-specific customizations.

### __init__.py

Empty file.

### File structure — driven by discovered capabilities

The file structure depends on whether the agent has extra env vars (discovered in Phase 1). Both patterns produce the same three files, but the distribution of logic differs.

---

### If `has_extra_env_vars` is false (no extra env vars)

**conftest.py** — Two-line shared fixture re-export:

```python
# Re-export shared integration fixtures so pytest discovers them.
from integration.conftest import cluster_auth, repo_root  # noqa: F401
```

**test_deployment.py** — Contains all per-agent logic (fixtures, env file writer, deployment lifecycle, and the test):

1. **Imports**: `from __future__ import annotations`, stdlib (`logging`, `os`), `pytest`, then `integration.utils` imports (`MakeTargetError`, `RouteNotFoundError`, `get_route`, `health_check`, `load_agent_name`, `resolve_agent_dir`, `run_make`)
2. **`INTERNAL_REGISTRY`** constant: `"image-registry.openshift-image-registry.svc:5000"`
3. **`agent_dir` fixture** (module scope): returns `resolve_agent_dir(__file__)`
4. **`agent_name` fixture** (module scope): returns `load_agent_name(agent_dir)`
5. **`_write_env_file()` function**: validates `("BASE_URL", "MODEL_ID")`, writes `.env` file, preserves any pre-existing `.env` for restore on teardown
6. **`deployed_agent` fixture** (module scope): orchestrates build-openshift (600s timeout) → deploy (300s timeout) → get route → yield URL → undeploy (120s timeout) → restore/cleanup `.env`
7. **`test_health_endpoint`**: marked `@pytest.mark.integration`, calls `health_check(f"{deployed_agent}/health", retries=12, backoff=5.0)`, asserts `status == "healthy"` and `agent_initialized is True`

Template — `_write_env_file`:

```python
def _write_env_file(agent_dir, container_image):
    missing = [v for v in ("BASE_URL", "MODEL_ID") if v not in os.environ]
    if missing:
        pytest.fail(
            f"Missing required env vars: {', '.join(missing)}. "
            "Set them in the CI workflow or export locally."
        )
    env_path = agent_dir / ".env"
    orig_env = None
    if env_path.exists():
        orig_env = env_path.read_text(encoding="utf-8")
    env_path.write_text(
        f"API_KEY={os.environ.get('API_KEY', 'not-needed')}\n"
        f"BASE_URL={os.environ['BASE_URL']}\n"
        f"MODEL_ID={os.environ['MODEL_ID']}\n"
        f"CONTAINER_IMAGE={container_image}\n",
        encoding="utf-8",
    )
    return env_path, orig_env
```

Template — `deployed_agent` fixture (single `except` block, `.env` restore):

```python
@pytest.fixture(scope="module")
def deployed_agent(cluster_auth, agent_dir, agent_name):
    namespace = cluster_auth["namespace"]
    container_image = f"{INTERNAL_REGISTRY}/{namespace}/{agent_name}:latest"
    env_path, orig_env = _write_env_file(agent_dir, container_image)

    deployed = False
    try:
        logger.info("Building image on cluster via build-openshift...")
        run_make("build-openshift", cwd=agent_dir, timeout=600)

        logger.info("Deploying to cluster...")
        run_make("deploy", cwd=agent_dir, timeout=300)
        deployed = True

        route_url = get_route(agent_name, namespace=namespace)
        logger.info("Agent deployed at %s", route_url)

        yield route_url

    except (MakeTargetError, RouteNotFoundError) as exc:
        pytest.fail(f"Deployment failed: {exc}")

    finally:
        if deployed:
            logger.info("Tearing down deployment...")
            try:
                run_make("undeploy", cwd=agent_dir, timeout=120)
            except MakeTargetError:
                logger.warning(
                    "Cleanup failed — manual undeploy may be needed", exc_info=True
                )
        if orig_env is not None:
            try:
                env_path.write_text(orig_env, encoding="utf-8")
            except Exception:
                logger.exception("Failed to restore pre-existing .env at %s", env_path)
        else:
            env_path.unlink(missing_ok=True)
```

---

### If `has_extra_env_vars` is true (agent needs additional env vars)

When the agent has extra env vars (especially for infrastructure dependencies like databases or vector stores), the fixture logic moves to `conftest.py` and `test_deployment.py` becomes minimal. This separation keeps the deployment orchestration (which is more complex for these agents) cleanly isolated.

**conftest.py** — Full file with all fixtures and deployment logic:

```python
from __future__ import annotations

import logging
import os

import pytest
from integration.conftest import cluster_auth, repo_root  # noqa: F401
from integration.utils import (
    MakeTargetError,
    RouteNotFoundError,
    get_route,
    load_agent_name,
    resolve_agent_dir,
    run_make,
)

logger = logging.getLogger(__name__)

INTERNAL_REGISTRY = "image-registry.openshift-image-registry.svc:5000"

_REQUIRED_ENV = ("BASE_URL", "MODEL_ID", "<EXTRA_VAR_1>", "<EXTRA_VAR_2>")


@pytest.fixture(scope="module")
def agent_dir():
    return resolve_agent_dir(__file__)


@pytest.fixture(scope="module")
def agent_name(agent_dir):
    return load_agent_name(agent_dir)


def _write_env_file(agent_dir, container_image):
    """Write a .env file with base and agent-specific env vars."""
    missing = [v for v in _REQUIRED_ENV if v not in os.environ]
    if missing:
        pytest.fail(
            f"Missing required env vars for <AGENT_DESCRIPTION>: {', '.join(missing)}. "
            "Set them in the CI workflow or export locally."
        )
    env_path = agent_dir / ".env"
    env_path.write_text(
        f"API_KEY={os.environ.get('API_KEY', 'not-needed')}\n"
        f"BASE_URL={os.environ['BASE_URL']}\n"
        f"MODEL_ID={os.environ['MODEL_ID']}\n"
        f"CONTAINER_IMAGE={container_image}\n"
        f"<EXTRA_VAR_1>={os.environ['<EXTRA_VAR_1>']}\n"
        f"<EXTRA_VAR_2>={os.environ['<EXTRA_VAR_2>']}\n"
        # ... include ALL extra vars discovered in Phase 1
        # For vars with sensible defaults, use os.environ.get('<VAR>', '<default>')
    )
    return env_path


@pytest.fixture(scope="module")
def deployed_agent(cluster_auth, agent_dir, agent_name):
    namespace = cluster_auth["namespace"]
    container_image = f"{INTERNAL_REGISTRY}/{namespace}/{agent_name}:latest"
    env_path = _write_env_file(agent_dir, container_image)

    deployed = False
    try:
        try:
            logger.info("Building image on cluster via build-openshift...")
            run_make("build-openshift", cwd=agent_dir, timeout=600)

            logger.info("Deploying to cluster...")
            run_make("deploy", cwd=agent_dir, timeout=300)
            deployed = True

            route_url = get_route(agent_name, namespace=namespace)
            logger.info("Agent deployed at %s", route_url)
        except (MakeTargetError, RouteNotFoundError) as exc:
            pytest.fail(f"Deployment failed: {exc}")
        except Exception as exc:
            pytest.fail(f"Unexpected error during deployment setup: {exc}")

        yield route_url

    finally:
        if deployed:
            logger.info("Tearing down deployment...")
            try:
                run_make("undeploy", cwd=agent_dir, timeout=120)
            except MakeTargetError:
                logger.warning(
                    "Cleanup failed — manual undeploy may be needed", exc_info=True
                )
        env_path.unlink(missing_ok=True)
```

Key differences from the no-extra-env-vars pattern:
- `_REQUIRED_ENV` tuple at module level lists all required vars (including extra ones)
- Error message in `_write_env_file` describes the agent type (e.g., "database-backed agent", "RAG agent")
- `deployed_agent` uses nested `try/except` with an additional `except Exception` catch — infrastructure dependencies (DB connections, vector store init) can fail in unexpected ways
- `_write_env_file` returns just `env_path` (no `.env` restore — these agents typically don't have a pre-existing `.env` on CI)

**test_deployment.py** — Minimal, contains only the test function:

```python
from __future__ import annotations

import pytest
from integration.utils import health_check


@pytest.mark.integration
def test_health_endpoint(deployed_agent):
    route_url = deployed_agent
    result = health_check(f"{route_url}/health", retries=12, backoff=5.0)

    assert result["status"] == "healthy"
    assert result["agent_initialized"] is True
```

Adapt the templates above:
- Replace `<EXTRA_VAR_*>` with the actual extra var names discovered in Phase 1
- Replace `<AGENT_DESCRIPTION>` with a short label derived from `has_infrastructure_deps` — e.g., "database-backed agent" (PostgreSQL), "RAG agent" (vector store), or "agent with <service> dependency"

## Phase 3: Add Makefile Target

If `test-integration` target does NOT exist in the agent's Makefile:

1. Add `test-integration` to the `.PHONY` declaration
2. Add the target after the existing `test` target:

```makefile
test-integration: ## Run integration deployment test
	PYTHONPATH=$$(git rev-parse --show-toplevel)/tests \
	  uv run --extra dev python -m pytest tests/integration/test_deployment.py \
	    -v --tb=long --junitxml=results.xml
```

Also ensure the existing `test` target ignores the integration directory:
```makefile
test: ## Run unit tests
	uv run --extra dev python -m pytest tests/ --ignore=tests/integration --ignore=tests/behavioral $(PYTEST_ARGS)
```

If the `test` target does not already have `--ignore=tests/integration`, add it.

## Phase 4: Update CI Workflow

Add a matrix entry to `.github/workflows/agent-deployment-test.yaml` under `strategy.matrix.agent`:

```yaml
- { name: <framework>-<agent-slug>, dir: agents/<framework>/templates/<agent_name> }
```

Where `<agent-slug>` is a kebab-case name derived from the agent name (e.g., `websearch-agent`, `adk-agent`, `db-memory-agent`).

### If `has_extra_env_vars` is false

No further CI changes needed — the job-level `env:` block already provides `API_KEY`, `BASE_URL`, and `MODEL_ID`.

### If `has_extra_env_vars` is true

Add agent-specific env vars scoped to the agent via `matrix.include`. Do NOT add the vars to the top-level `env:` block (they would be set for all agents unnecessarily). Use the `include:` mechanism to inject them as job-level env vars — this avoids echoing secrets to `$GITHUB_ENV` via shell:

```yaml
strategy:
  matrix:
    agent:
      # ... existing entries ...
      - { name: <framework>-<agent-slug>, dir: agents/<framework>/templates/<agent_name> }
    include:
      - agent: { name: <framework>-<agent-slug>, dir: agents/<framework>/templates/<agent_name> }
        EXTRA_VAR_1: ${{ vars.EXTRA_VAR_1 }}
        EXTRA_VAR_2: ${{ secrets.EXTRA_VAR_2 }}
```

Then reference the matrix values in the job's `env:` block or step-level `env:`:

```yaml
- name: Run integration test
  working-directory: ${{ matrix.agent.dir }}
  env:
    EXTRA_VAR_1: ${{ matrix.EXTRA_VAR_1 }}
    EXTRA_VAR_2: ${{ matrix.EXTRA_VAR_2 }}
  run: make test-integration
```

Use `vars.*` for non-sensitive values (model names, hostnames, ports) and `secrets.*` for credentials (passwords, tokens). Check `.env.example` and `agent.yaml` to determine which is which.

## Phase 5: Validate

### 5a: Verify test collection

From the agent directory:

```bash
PYTHONPATH=$(git rev-parse --show-toplevel)/tests \
  uv run --extra dev python -m pytest tests/integration/test_deployment.py --collect-only -q
```

Must show 1 test collected, no import errors.

### 5b: Live cluster test (if available)

Check cluster access:

```bash
oc whoami
```

If logged in and in `ci-testing` namespace, run:

```bash
make test-integration
```

This builds the agent image on-cluster, deploys via Helm, health-checks, and tears down. All steps must succeed.

**If no cluster access**: skip this step. Document that live testing was not performed. Test collection (5a) is sufficient for the PR.

### 5c: Cross-agent consistency check

Verify the new test files match the established pattern for the agent's discovered capabilities.

**Common to all agents:**

1. `conftest.py` re-exports shared fixtures via `from integration.conftest import cluster_auth, repo_root`
2. `_write_env_file` validates the correct required env vars for this agent (matching what was discovered in Phase 1)
3. `deployed_agent` fixture follows the standard build → deploy → yield → undeploy → cleanup flow
4. `test_deployment.py` has `@pytest.mark.integration` on `test_health_endpoint` with `health_check()` call asserting `status == "healthy"` and `agent_initialized is True`

**If `has_extra_env_vars` is false:**

5. `conftest.py` is the 2-line re-export pattern (matching react_agent, crewai/websearch_agent, human_in_the_loop)
6. `test_deployment.py` contains `INTERNAL_REGISTRY`, `agent_dir`, `agent_name`, `_write_env_file`, `deployed_agent`, and `test_health_endpoint`

**If `has_extra_env_vars` is true:**

5. `conftest.py` contains `INTERNAL_REGISTRY`, `_REQUIRED_ENV`, `agent_dir`, `agent_name`, `_write_env_file`, and `deployed_agent` (matching the agentic_rag pattern)
6. `test_deployment.py` is minimal — only imports and `test_health_endpoint`
7. `_REQUIRED_ENV` tuple includes all extra vars discovered in Phase 1

### 5d: Verify CI workflow YAML

Confirm the workflow file has valid YAML syntax after editing. The matrix entry must follow the format: `{ name: <slug>, dir: agents/<path> }`.

## Definition of Done

- [ ] `tests/integration/__init__.py` created
- [ ] `tests/integration/conftest.py` created (re-export pattern or full fixtures, per discovered capabilities)
- [ ] `tests/integration/test_deployment.py` created with health check test
- [ ] `test-integration` Makefile target present
- [ ] `test` Makefile target ignores `tests/integration/`
- [ ] CI workflow matrix updated with new agent entry
- [ ] Phase 5a: test collection passes
- [ ] Phase 5b: live cluster test passes (or waived if no cluster access)
- [ ] Phase 5c: cross-agent consistency verified
- [ ] Jira ticket updated with results (if ticket provided)
