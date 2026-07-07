---
name: add-integration-tests
description: >-
  Add integration deployment tests (health-check on OpenShift) to any agent in
  the agentic-starter-kits repo — standard, external-registry, or pre-deployed.
  Creates conftest.py, test_deployment.py, __init__.py, adds test-integration
  Makefile target, and updates the CI workflow matrix. Use when implementing
  integration tests, deployment tests, or health-check tests for a new agent.
argument-hint: "<agent_path> [JIRA-KEY]"
---
# Add Integration Tests to an Agent

End-to-end workflow for adding integration deployment tests to any agent in the agentic-starter-kits repo. Produces per-agent pytest integration tests that build, deploy via Helm, validate health endpoints, and tear down. Supports standard agents (on-cluster builds), external-registry agents (local build + push), and pre-deployed agents (flow-import, docker-compose).

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

- **Agent path**: relative to `agents/` (e.g., `langgraph/templates/react_agent`, `crewai/templates/websearch_agent`, `a2a/langgraph_crewai_agent`)
- **Jira key**: optional ticket reference for context

If no agent path is provided, ask the user which agent to add integration tests to.

## Phase 0: Parse Input and Gather Jira Context

**If a Jira key is provided**: Fetch the ticket to extract scope, acceptance criteria, and parent epic for context.

**If no ticket is provided**: Ask the user for the Jira ticket key or confirm that no ticket tracking is needed.

Validate prerequisites:

1. Working directory is the agentic-starter-kits repo root (`AGENTS.md` exists)
2. Agent directory exists at `agents/<agent_path>/`
3. Agent has `agent.yaml` and `Makefile`
4. If `agent.yaml` or `Makefile` is missing, stop and tell the user this workflow cannot proceed
5. Agent has a recognized entrypoint — `main.py` (standard), `entrypoint.sh` (A2A/custom), or `deploymentModel: flow-import` in `agent.yaml` (pre-deployed). If none match, stop and tell the user the agent's pattern is not yet supported — file a feature request.

## Phase 1: Investigate the Agent

Gather these facts — the discovered capabilities drive all subsequent phases:

1. **Agent name**: Read `agent.yaml` — extract the `name` field
2. **Existing integration tests**: Check if `tests/integration/test_deployment.py` already exists. If yes, stop and inform the user — no work needed
3. **Makefile targets**: Check which of these targets exist: `test-integration`, `build-openshift`, `build`, `push`, `deploy`, `undeploy`. This determines `deploy_method` (see step 5)

### Capability discovery

4. **Required env vars**: Read `agent.yaml` `env.required` section AND the env template file (`.env.example` or `template.env` — see step 7). Identify every env var the agent needs. Then determine:

   - **`has_extra_env_vars`**: Does the agent require vars beyond `BASE_URL`, `MODEL_ID` (and `API_KEY` which is always optional)? If yes, record the list of extra var names.
   - **`has_infrastructure_deps`**: Do the extra vars indicate pre-provisioned services — databases (`POSTGRES_*`), vector stores (`VECTOR_STORE_*`, `MILVUS_*`), message queues, etc.? If yes, record what kind of infrastructure. This drives the `<AGENT_DESCRIPTION>` in `_write_env_file` error messages (Phase 2) — e.g., "database-backed agent", "RAG agent with vector store".

   Examples of what you might discover:
   - No extra vars → majority pattern (react_agent, crewai/websearch_agent, human_in_the_loop)
   - RAG vars (`EMBEDDING_MODEL`, `VECTOR_STORE_ID`) → extra env vars, infrastructure dep (vector store)
   - DB vars (`POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`) → extra env vars, infrastructure dep (database)

   **For `pre_deployed` agents** (see step 5): env file writing may not apply — the agent is already configured and running. Still record what env vars the agent expects, as they may be needed for CI configuration.

### Structural discovery

5. **`deploy_method`**: Determined from Makefile targets discovered in step 3 and `agent.yaml`:

   - **`openshift_build`** → `build-openshift` target exists. Standard on-cluster build via OpenShift BuildConfig. This is the majority pattern.
   - **`external_registry`** → `build` + `push` targets exist but no `build-openshift`. Agent builds locally with podman/docker and pushes to an external registry (e.g., quay.io). Requires `CONTAINER_IMAGE` env var.
   - **`pre_deployed`** → No `build-openshift`, `build`, `push`, or `deploy` targets. Agent is deployed externally (e.g., `deploymentModel: flow-import` in `agent.yaml`, docker-compose). The integration test only verifies health on the already-running agent.
   - **None of the above** → stop and tell the user the agent's build/deploy pattern is not yet supported.

6. **`entrypoint`**: What starts the agent. Discovered by checking which files exist in the agent directory:
   - `main.py` → standard Python entrypoint (majority pattern)
   - `entrypoint.sh` → shell entrypoint (e.g., A2A agents)
   - Neither, with `deploymentModel: flow-import` in `agent.yaml` → pre-deployed, no local entrypoint
   Used only for agent classification — does not affect test file content.

7. **`env_template`**: Which env template file the agent uses. Discovered by checking file existence:
   - `.env.example` → standard pattern (default)
   - `template.env` → alternative pattern (e.g., A2A agents)
   - Neither exists → `pre_deployed` agents may have no env template (acceptable)
   Affects which file to read for env var discovery (step 4) and how `_write_env_file` references variable names.

8. **`health_endpoint`**: The path to health-check after deployment. Discovered by scanning agent code or config for health route definitions:
   - `/health` → standard (default). Most agents register this in their web framework.
   - `/.well-known/agent-card.json` → A2A agents. The agent card endpoint doubles as a health probe.
   - Other paths → discovered from the agent's route definitions.
   The test template uses this value instead of hardcoding `/health`.

9. **`health_response_schema`**: What to assert on the health endpoint response. Determined by inspecting the health handler or the protocol:
   - **`standard`** → assert `result["status"] == "healthy"` and `result["agent_initialized"] is True`. Current default for FastAPI-based agents.
   - **`status_only`** → assert `result["status"] == "healthy"` only. For agents whose `/health` returns `{"status":"healthy"}` without `agent_initialized`.
   - **`agent_card`** → validate response is valid JSON containing required A2A fields (at minimum `name`). For agents whose health is checked via `/.well-known/agent-card.json`.
   - **`http_200`** → just assert HTTP 200 status code. For non-JSON health endpoints or agents where the response body format is not guaranteed.

10. **`has_multiple_deployments`** and **`deployment_names`**: Discovered by inspecting the agent's Helm chart templates.
    - Find the chart directory: check the agent's Makefile for `CHART_DIR` or `CHART_PATH`
    - Look in `<chart_dir>/templates/` for files containing `kind: Deployment`
    - If more than one Deployment manifest exists, set `has_multiple_deployments: true` and record each deployment's `metadata.name` pattern (e.g., `["a2a-langgraph-agent", "a2a-crew-agent"]`)
    - For single-deployment agents (the vast majority), both are `false`/empty
    - Multi-deployment agents create separate routes per deployment — the test must verify health on each.

11. **Reference template**: Read an existing agent's integration test to ground the patterns:
    - Always read: `agents/langgraph/templates/react_agent/tests/integration/test_deployment.py`
    - If `has_extra_env_vars`: also read `agents/langgraph/templates/agentic_rag/tests/integration/conftest.py` and `agents/langgraph/templates/agentic_rag/tests/integration/test_deployment.py`
    - If `deploy_method` is `external_registry` or `pre_deployed`: also check if any non-standard agent already has integration tests (e.g., `agents/a2a/langgraph_crewai_agent/tests/integration/`) and read them as reference if they exist

    **Note**: When the reference code differs from the templates in Phase 2, the Phase 2 templates take precedence. The reference files are for understanding the overall structure, not for copying import styles or minor details verbatim. In particular, always use `from integration.conftest import cluster_auth, repo_root` (not `import integration.conftest`) — the explicit form is required for pytest fixture discovery and is enforced by the eval criteria.

Record all discovered capabilities — they determine the file structure (Phase 2), CI config (Phase 4), and consistency checks (Phase 5c). The full trait set is: `has_extra_env_vars`, `has_infrastructure_deps`, `deploy_method`, `entrypoint`, `env_template`, `health_endpoint`, `health_response_schema`, `has_multiple_deployments`, `deployment_names`.

## Phase 2: Create Test Files

### Directory structure

```
agents/<agent_path>/tests/integration/
  __init__.py
  conftest.py
  test_deployment.py
```

**Note**: `<agent_path>` is the full path under `agents/`. Standard agents use `<framework>/templates/<agent_name>`, but some agents live outside `templates/` (e.g., `a2a/langgraph_crewai_agent`). Use the actual agent path discovered in Phase 0.

**If `tests/integration/` already exists**: inspect existing files before creating anything. Preserve any agent-specific customizations.

### __init__.py

Empty file.

### File structure — driven by discovered capabilities

The file structure depends on the traits discovered in Phase 1. The primary axes are `deploy_method` and `has_extra_env_vars`. All patterns produce the same three files, but the distribution of logic differs.

---

### If `deploy_method` is `openshift_build` and `has_extra_env_vars` is false (no extra env vars)

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

### If `deploy_method` is `openshift_build` and `has_extra_env_vars` is true (agent needs additional env vars)

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

**Note**: The two patterns above (`has_extra_env_vars` false/true) apply only when `deploy_method` is `openshift_build`. For other deploy methods, see the patterns below.

---

### If `deploy_method` is `external_registry`

When the agent builds locally and pushes to an external container registry (no `build-openshift` target), the deployment fixture uses `make build` + `make push` instead of `make build-openshift`, and requires `CONTAINER_IMAGE` from environment (not constructed from the internal registry).

This pattern always places fixture logic in `conftest.py` because external-registry agents invariably need extra configuration.

**conftest.py** — Full file with external-registry deployment logic:

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

_REQUIRED_ENV = ("BASE_URL", "MODEL_ID", "CONTAINER_IMAGE")
# ^^^ Add any agent-specific extra vars discovered in Phase 1


@pytest.fixture(scope="module")
def agent_dir():
    return resolve_agent_dir(__file__)


@pytest.fixture(scope="module")
def agent_name(agent_dir):
    return load_agent_name(agent_dir)


def _write_env_file(agent_dir):
    """Write a .env from env vars. CONTAINER_IMAGE comes from environment (external registry)."""
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
        f"CONTAINER_IMAGE={os.environ['CONTAINER_IMAGE']}\n"
        # ... include ALL extra vars discovered in Phase 1
    )
    return env_path


@pytest.fixture(scope="module")
def deployed_agent(cluster_auth, agent_dir, agent_name):
    namespace = cluster_auth["namespace"]
    env_path = _write_env_file(agent_dir)

    deployed = False
    try:
        try:
            logger.info("Building container image locally...")
            run_make("build", cwd=agent_dir, timeout=600)

            logger.info("Pushing image to external registry...")
            run_make("push", cwd=agent_dir, timeout=300)

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

Key differences from the `openshift_build` patterns:
- **No `INTERNAL_REGISTRY` constant** — the container image path comes from `CONTAINER_IMAGE` env var (pointing to an external registry like `quay.io/org/image:tag`)
- **`_write_env_file` takes no `container_image` parameter** — reads `CONTAINER_IMAGE` from `os.environ` directly
- **`CONTAINER_IMAGE` is in `_REQUIRED_ENV`** — must be set in environment, not computed
- **Build uses `run_make("build")` + `run_make("push")`** instead of `run_make("build-openshift")`
- **Nested `try/except`** with additional `except Exception` catch — external registry operations can fail in unexpected ways (auth failures, network issues)
- **No `.env` restore** — these agents typically don't have a pre-existing `.env` on CI

#### Multi-deployment variant

If `has_multiple_deployments` is true, the `deployed_agent` fixture must discover routes for all deployments. Replace the single `get_route` call with a loop over `deployment_names`, and add an `all_routes` fixture for tests that need to verify each component:

```python
_DEPLOYMENT_NAMES = ["<DEPLOY_NAME_1>", "<DEPLOY_NAME_2>"]
# ^^^ Replace with actual deployment names discovered in Phase 1


@pytest.fixture(scope="module")
def all_routes(deployed_agent):
    """Routes for all deployments, populated by deployed_agent fixture."""
    return getattr(all_routes, "_routes", {})


@pytest.fixture(scope="module")
def deployed_agent(cluster_auth, agent_dir, agent_name):
    namespace = cluster_auth["namespace"]
    env_path = _write_env_file(agent_dir)

    deployed = False
    try:
        try:
            logger.info("Building container image locally...")
            run_make("build", cwd=agent_dir, timeout=600)

            logger.info("Pushing image to external registry...")
            run_make("push", cwd=agent_dir, timeout=300)

            logger.info("Deploying to cluster...")
            run_make("deploy", cwd=agent_dir, timeout=300)
            deployed = True

            routes = {}
            for deploy_name in _DEPLOYMENT_NAMES:
                routes[deploy_name] = get_route(deploy_name, namespace=namespace)
                logger.info("Deployment %s at %s", deploy_name, routes[deploy_name])
            all_routes._routes = routes

            primary = next(iter(routes.values()))
        except (MakeTargetError, RouteNotFoundError) as exc:
            pytest.fail(f"Deployment failed: {exc}")
        except Exception as exc:
            pytest.fail(f"Unexpected error during deployment setup: {exc}")

        yield primary

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

Replace `<DEPLOY_NAME_*>` with the actual deployment names discovered in Phase 1 (e.g., `["a2a-langgraph-agent", "a2a-crew-agent"]`).

---

### If `deploy_method` is `pre_deployed`

When the agent is deployed externally (flow-import, docker-compose, or another mechanism), the integration test only verifies the already-running agent's health. There is no build/push/deploy/undeploy lifecycle.

**conftest.py** — Minimal, with pre-deployed fixture:

```python
from __future__ import annotations

import logging

import pytest
from integration.conftest import cluster_auth, repo_root  # noqa: F401
from integration.utils import (
    RouteNotFoundError,
    get_route,
    load_agent_name,
    resolve_agent_dir,
)

logger = logging.getLogger(__name__)


@pytest.fixture(scope="module")
def agent_dir():
    return resolve_agent_dir(__file__)


@pytest.fixture(scope="module")
def agent_name(agent_dir):
    return load_agent_name(agent_dir)


@pytest.fixture(scope="module")
def deployed_agent(cluster_auth, agent_name):
    namespace = cluster_auth["namespace"]
    try:
        route_url = get_route(agent_name, namespace=namespace)
    except RouteNotFoundError as exc:
        pytest.fail(
            f"Pre-deployed agent route not found: {exc}. "
            "Ensure the agent is deployed before running integration tests."
        )
    logger.info("Pre-deployed agent at %s", route_url)
    yield route_url
    # No teardown — agent is managed externally
```

Key differences from lifecycle-based patterns:
- **No `_write_env_file`** — agent is already configured and running
- **No build/push/deploy steps** — fixture only discovers the existing route
- **No teardown** — the agent is managed externally (flow-import, docker-compose, etc.)
- **No `MakeTargetError` or `run_make` imports** — no Makefile targets are called
- **Clear error message** if route is not found — tells the user to deploy first

---

### Health assertion patterns

The `test_health_endpoint` test adapts its assertions based on the discovered `health_response_schema`. These patterns apply to all deploy methods.

**`standard`** (default — no change from existing pattern):

```python
@pytest.mark.integration
def test_health_endpoint(deployed_agent):
    route_url = deployed_agent
    result = health_check(f"{route_url}/health", retries=12, backoff=5.0)
    assert result["status"] == "healthy"
    assert result["agent_initialized"] is True
```

**`status_only`** (agent returns `{"status":"healthy"}` without `agent_initialized`):

```python
@pytest.mark.integration
def test_health_endpoint(deployed_agent):
    route_url = deployed_agent
    result = health_check(f"{route_url}/health", retries=12, backoff=5.0)
    assert result["status"] == "healthy"
```

**`agent_card`** (health is verified via the A2A agent card endpoint):

```python
import requests

@pytest.mark.integration
def test_health_endpoint(deployed_agent):
    route_url = deployed_agent
    resp = requests.get(
        f"{route_url}/.well-known/agent-card.json",
        timeout=30,
        verify=False,
    )
    assert resp.status_code == 200, f"Agent card endpoint returned {resp.status_code}"
    card = resp.json()
    assert "name" in card, "Agent card missing 'name' field"
```

**`http_200`** (just verify the endpoint returns HTTP 200):

```python
import requests

@pytest.mark.integration
def test_health_endpoint(deployed_agent):
    route_url = deployed_agent
    resp = requests.get(
        f"{route_url}<HEALTH_ENDPOINT>",
        timeout=30,
        verify=False,
    )
    assert resp.status_code == 200, f"Health endpoint returned {resp.status_code}"
```

Replace `<HEALTH_ENDPOINT>` with the discovered `health_endpoint` path.

Use `health_check()` from `integration.utils` for `standard` and `status_only` schemas (it handles retries and backoff). For `agent_card` and `http_200`, use `requests.get()` directly — `health_check()` assumes JSON with specific fields.

### Multi-deployment health test

If `has_multiple_deployments` is true, add a second test in `test_deployment.py` that verifies all deployments:

```python
@pytest.mark.integration
def test_all_deployments_healthy(all_routes):
    """Verify every deployment in the multi-component agent is healthy."""
    assert all_routes, "No routes discovered — deployment may have failed"
    for name, route_url in all_routes.items():
        # Use the appropriate health assertion for the discovered health_response_schema
        resp = requests.get(
            f"{route_url}<HEALTH_ENDPOINT>",
            timeout=30,
            verify=False,
        )
        assert resp.status_code == 200, (
            f"Deployment {name} health check failed: HTTP {resp.status_code}"
        )
```

Adapt the inner assertions to match the discovered `health_response_schema` for the agent.

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

**Note**: The `test-integration` target is identical regardless of `deploy_method`. The deployment method differences are handled entirely in the fixture code (`conftest.py`), not in the Makefile target. The `uv run` + `pytest` invocation is the same for all agents.

## Phase 4: Update CI Workflow

Add a matrix entry to `.github/workflows/agent-deployment-test.yaml` under `strategy.matrix.agent`:

```yaml
- { name: <framework>-<agent-slug>, dir: agents/<agent_path> }
```

Where `<agent-slug>` is a kebab-case name derived from the agent name (e.g., `websearch-agent`, `adk-agent`, `langgraph-crewai`), and `<agent_path>` is the full path under `agents/` (e.g., `langgraph/templates/react_agent` for standard agents, `a2a/langgraph_crewai_agent` for non-standard agents).

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

Use `vars.*` for non-sensitive values (model names, hostnames, ports) and `secrets.*` for credentials (passwords, tokens). Check the env template file (`.env.example` or `template.env`) and `agent.yaml` to determine which is which.

### If `deploy_method` is `external_registry`

External-registry agents need `CONTAINER_IMAGE` and potentially container registry credentials in CI. Add these via `matrix.include`:

```yaml
strategy:
  matrix:
    agent:
      # ... existing entries ...
      - { name: <framework>-<agent-slug>, dir: agents/<agent_path> }
    include:
      - agent: { name: <framework>-<agent-slug>, dir: agents/<agent_path> }
        CONTAINER_IMAGE: ${{ vars.CONTAINER_IMAGE_<AGENT_SLUG> }}
```

Then reference in the job step:

```yaml
- name: Run integration test
  working-directory: ${{ matrix.agent.dir }}
  env:
    CONTAINER_IMAGE: ${{ matrix.CONTAINER_IMAGE }}
  run: make test-integration
```

If the CI environment requires container registry authentication for push/pull, add registry login steps before the test step. Consult the existing CI workflow for the cluster's registry auth pattern.

**Note**: External-registry agents may also have `has_extra_env_vars: true` (both traits apply independently). Apply both `matrix.include` mechanisms if needed — combine `CONTAINER_IMAGE` and agent-specific vars in the same `include` entry.

### If `deploy_method` is `pre_deployed`

Pre-deployed agents need no build/push CI steps. The agent must already be deployed on the CI cluster. The matrix entry still follows the standard format:

```yaml
- { name: <framework>-<agent-slug>, dir: agents/<agent_path> }
```

No additional `matrix.include` vars are typically needed — the fixture discovers the route from the cluster. If the agent runs in a different namespace than the standard CI namespace, add a namespace override via `matrix.include`.

## Phase 5: Validate

### 5a: Verify test collection

From the agent directory:

```bash
PYTHONPATH=$(git rev-parse --show-toplevel)/tests \
  uv run --extra dev python -m pytest tests/integration/test_deployment.py --collect-only -q
```

Must show 1 test collected, no import errors. **For `has_multiple_deployments` agents**: expect 2 tests (`test_health_endpoint` and `test_all_deployments_healthy`).

### 5b: Live cluster test (if available)

Check cluster access:

```bash
oc whoami
```

If logged in and in `ci-testing` namespace, run:

```bash
make test-integration
```

For `deploy_method: openshift_build`: this builds the agent image on-cluster, deploys via Helm, health-checks, and tears down. All steps must succeed.

**For `deploy_method: external_registry`**: the live test runs `make build` + `make push` instead of `build-openshift`. This requires container registry credentials (e.g., `podman login quay.io`) and the `CONTAINER_IMAGE` env var set. If registry auth is unavailable, skip the live test and document the reason.

**For `deploy_method: pre_deployed`**: the live test only verifies the already-deployed agent's health. The agent must be running on the cluster before the test is invoked.

**If no cluster access**: skip this step. Document that live testing was not performed. Test collection (5a) is sufficient for the PR.

### 5c: Cross-agent consistency check

Verify the new test files match the established pattern for the agent's discovered capabilities.

**Common to all agents:**

1. `conftest.py` re-exports shared fixtures via `from integration.conftest import cluster_auth, repo_root`
2. `test_deployment.py` has `@pytest.mark.integration` on `test_health_endpoint`
3. Health assertions match the discovered `health_response_schema`

**If `deploy_method` is `openshift_build` and `has_extra_env_vars` is false:**

4. `conftest.py` is the 2-line re-export pattern (matching react_agent, crewai/websearch_agent, human_in_the_loop)
5. `test_deployment.py` contains `INTERNAL_REGISTRY`, `agent_dir`, `agent_name`, `_write_env_file`, `deployed_agent`, and `test_health_endpoint`
6. `_write_env_file` validates `("BASE_URL", "MODEL_ID")`
7. `deployed_agent` fixture calls `run_make("build-openshift")` → `run_make("deploy")` → yield → `run_make("undeploy")`

**If `deploy_method` is `openshift_build` and `has_extra_env_vars` is true:**

4. `conftest.py` contains `INTERNAL_REGISTRY`, `_REQUIRED_ENV`, `agent_dir`, `agent_name`, `_write_env_file`, and `deployed_agent` (matching the agentic_rag pattern)
5. `test_deployment.py` is minimal — only imports and `test_health_endpoint`
6. `_REQUIRED_ENV` tuple includes all extra vars discovered in Phase 1

**If `deploy_method` is `external_registry`:**

4. `conftest.py` contains `_REQUIRED_ENV`, `agent_dir`, `agent_name`, `_write_env_file`, and `deployed_agent`
5. **No `INTERNAL_REGISTRY` constant** — `CONTAINER_IMAGE` comes from environment
6. `_write_env_file` takes no `container_image` parameter — reads `CONTAINER_IMAGE` from `os.environ`
7. `CONTAINER_IMAGE` is in `_REQUIRED_ENV` tuple
8. `deployed_agent` fixture calls `run_make("build")` + `run_make("push")` + `run_make("deploy")` (not `build-openshift`)
9. `test_deployment.py` is minimal — only imports and `test_health_endpoint`

**If `deploy_method` is `pre_deployed`:**

4. `conftest.py` contains `agent_dir`, `agent_name`, and `deployed_agent` — no `_write_env_file`, no `run_make` calls
5. `deployed_agent` fixture only discovers the existing route — no build/push/deploy/undeploy lifecycle
6. No teardown in the fixture (agent is managed externally)
7. `test_deployment.py` is minimal — only imports and `test_health_endpoint`

**If `has_multiple_deployments` is true:**

8. `test_all_deployments_healthy` test exists in `test_deployment.py`
9. All deployment names from Phase 1 are referenced in `_DEPLOYMENT_NAMES`
10. Each deployment's route is discovered and health-checked

**Health endpoint consistency:**

11. Health endpoint path in test matches the discovered `health_endpoint` value
12. Health response assertions match the discovered `health_response_schema` — e.g., `agent_card` agents do NOT assert `agent_initialized`, `status_only` agents do NOT assert `agent_initialized`

### 5d: Verify CI workflow YAML

Confirm the workflow file has valid YAML syntax after editing. The matrix entry must follow the format: `{ name: <slug>, dir: agents/<path> }`.

## Definition of Done

- [ ] `tests/integration/__init__.py` created
- [ ] `tests/integration/conftest.py` created (pattern determined by `deploy_method` and `has_extra_env_vars`)
- [ ] `tests/integration/test_deployment.py` created with health check test
- [ ] `test-integration` Makefile target present
- [ ] `test` Makefile target ignores `tests/integration/`
- [ ] CI workflow matrix updated with new agent entry
- [ ] Phase 5a: test collection passes
- [ ] Phase 5b: live cluster test passes (or waived if no cluster access)
- [ ] Phase 5c: cross-agent consistency verified
- [ ] Jira ticket updated with results (if ticket provided)

**If `deploy_method` is `external_registry`:**

- [ ] `deployed_agent` fixture uses `build` + `push` (not `build-openshift`)
- [ ] `CONTAINER_IMAGE` is a required env var in test files
- [ ] No `INTERNAL_REGISTRY` constant in generated test files

**If `deploy_method` is `pre_deployed`:**

- [ ] `deployed_agent` fixture only discovers existing route (no build/deploy lifecycle)
- [ ] No `_write_env_file` function in test files
- [ ] No `run_make` calls in `deployed_agent` fixture

**If `has_multiple_deployments` is true:**

- [ ] `test_all_deployments_healthy` test verifies all deployments
- [ ] All deployment names from Phase 1 are referenced in `_DEPLOYMENT_NAMES`

**If `health_response_schema` is not `standard`:**

- [ ] Health assertions match the discovered schema (no `agent_initialized` assertion for `status_only`, `agent_card`, or `http_200`)
