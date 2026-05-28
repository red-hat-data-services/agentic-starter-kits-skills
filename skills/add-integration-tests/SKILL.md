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

- **Agent path**: relative to `agents/` (e.g., `google/adk`, `llamaindex/websearch_agent`)
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

Gather these facts:

1. **Agent name**: Read `agent.yaml` — extract the `name` field
2. **Required env vars**: Read `agent.yaml` `env.required` section AND `.env.example`. Classify as:
   - **Simple**: only requires `BASE_URL`, `MODEL_ID` (and `API_KEY` which is always optional). This is the majority pattern (react_agent, crewai/websearch_agent, human_in_the_loop)
   - **Complex**: requires additional vars (e.g., `EMBEDDING_MODEL`, `VECTOR_STORE_ID` for RAG agents). Follow the agentic_rag pattern with extended `_write_env_file()`
3. **Existing integration tests**: Check if `tests/integration/test_deployment.py` already exists. If yes, stop and inform the user — no work needed
4. **Makefile targets**: Check if `test-integration`, `build-openshift`, `deploy`, `undeploy` targets exist. If `build-openshift` is missing, stop — the agent cannot be built on-cluster
5. **Reference template**: Read an existing agent's integration test for reference:
   - Simple agents: read `agents/langgraph/react_agent/tests/integration/test_deployment.py`
   - Complex agents: also read `agents/langgraph/agentic_rag/tests/integration/conftest.py` (for the `_write_env_file` pattern with extra env vars)

## Phase 2: Create Test Files

### Directory structure

```
agents/<framework>/<agent_name>/tests/integration/
  __init__.py
  conftest.py
  test_deployment.py
```

**If `tests/integration/` already exists**: inspect existing files before creating anything. Preserve any agent-specific customizations.

### __init__.py

Empty file.

### conftest.py

Two-line shared fixture re-export (majority pattern from 3 of 4 existing agents):

```python
# Re-export shared integration fixtures so pytest discovers them.
from integration.conftest import cluster_auth, repo_root  # noqa: F401
```

### test_deployment.py

Follow the canonical pattern from existing agents. The file contains all per-agent logic:

#### Standard patterns (must be consistent across agents)

1. **Imports**: `from __future__ import annotations`, stdlib (`logging`, `os`), `pytest`, then `integration.utils` imports (`MakeTargetError`, `RouteNotFoundError`, `get_route`, `health_check`, `load_agent_name`, `run_make`)
2. **`INTERNAL_REGISTRY`** constant: `"image-registry.openshift-image-registry.svc:5000"`
3. **`agent_dir` fixture** (module scope): returns `repo_root / "agents" / "<framework>" / "<agent_name>"`
4. **`agent_name` fixture** (module scope): returns `load_agent_name(agent_dir)`
5. **`_write_env_file()` function**: validates required env vars, writes `.env` file. For simple agents, check `("BASE_URL", "MODEL_ID")`. For complex agents, add agent-specific required vars
6. **`deployed_agent` fixture** (module scope): orchestrates build-openshift (600s timeout) → deploy (300s timeout) → get route → yield URL → undeploy (120s timeout) → cleanup `.env`
7. **`test_health_endpoint`**: marked `@pytest.mark.integration`, calls `health_check(f"{deployed_agent}/health", retries=12, backoff=5.0)`, asserts `status == "healthy"` and `agent_initialized is True`

#### Variation: Simple vs Complex agents

**Simple agent `_write_env_file`** (react_agent, crewai, hitl pattern):

```python
def _write_env_file(agent_dir, container_image):
    missing = [v for v in ("BASE_URL", "MODEL_ID") if v not in os.environ]
    if missing:
        pytest.fail(
            f"Missing required env vars: {', '.join(missing)}. "
            "Set them in the CI workflow or export locally."
        )
    env_path = agent_dir / ".env"
    env_path.write_text(
        f"API_KEY={os.environ.get('API_KEY', 'not-needed')}\n"
        f"BASE_URL={os.environ['BASE_URL']}\n"
        f"MODEL_ID={os.environ['MODEL_ID']}\n"
        f"CONTAINER_IMAGE={container_image}\n"
    )
    return env_path
```

**Complex agent `_write_env_file`** (agentic_rag pattern — adapt per agent's env vars):

```python
_REQUIRED_ENV = ("BASE_URL", "MODEL_ID", "<AGENT_SPECIFIC_VAR_1>", "<AGENT_SPECIFIC_VAR_2>")

def _write_env_file(agent_dir, container_image):
    missing = [v for v in _REQUIRED_ENV if v not in os.environ]
    if missing:
        pytest.fail(
            f"Missing required env vars: {', '.join(missing)}. "
            "Set them in the CI workflow or export locally."
        )
    env_path = agent_dir / ".env"
    env_path.write_text(
        f"API_KEY={os.environ.get('API_KEY', 'not-needed')}\n"
        f"BASE_URL={os.environ['BASE_URL']}\n"
        f"MODEL_ID={os.environ['MODEL_ID']}\n"
        f"CONTAINER_IMAGE={container_image}\n"
        f"<AGENT_SPECIFIC_VAR_1>={os.environ['<AGENT_SPECIFIC_VAR_1>']}\n"
        # ... additional vars as needed
    )
    return env_path
```

#### Variation: deployed_agent fixture error handling

**Simple agents** (react_agent, crewai, hitl): single `except (MakeTargetError, RouteNotFoundError)` block.

**Complex agents** (agentic_rag): nested `try/except` with additional `except Exception` catch for unexpected errors. Use this when the agent has extra deployment complexity.

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
- { name: <framework>-<agent-slug>, dir: agents/<framework>/<agent_name> }
```

Where `<agent-slug>` is a kebab-case name derived from the agent name (e.g., `websearch-agent`, `adk-agent`).

**If the agent needs extra env vars** beyond `API_KEY`, `BASE_URL`, `MODEL_ID`:
- Add agent-specific vars to the `env:` block, sourced from `${{ vars.VAR_NAME }}` or `${{ secrets.VAR_NAME }}` as appropriate
- Or add an `include:` entry in the matrix for agent-specific env vars

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

Verify the new test files match the established pattern:

1. `conftest.py` re-exports `cluster_auth` and `repo_root` from `integration.conftest`
2. `test_deployment.py` has the same structure as existing agents: `INTERNAL_REGISTRY`, `agent_dir`, `agent_name`, `_write_env_file`, `deployed_agent`, `test_health_endpoint`
3. `_write_env_file` validates the correct required env vars for this agent
4. `deployed_agent` fixture follows the standard build → deploy → yield → undeploy → cleanup flow

### 5d: Verify CI workflow YAML

Confirm the workflow file has valid YAML syntax after editing. The matrix entry must follow the format: `{ name: <slug>, dir: agents/<path> }`.

## Definition of Done

- [ ] `tests/integration/__init__.py` created
- [ ] `tests/integration/conftest.py` created with shared fixture re-exports
- [ ] `tests/integration/test_deployment.py` created with health check test
- [ ] `test-integration` Makefile target present
- [ ] `test` Makefile target ignores `tests/integration/`
- [ ] CI workflow matrix updated with new agent entry
- [ ] Phase 5a: test collection passes
- [ ] Phase 5b: live cluster test passes (or waived if no cluster access)
- [ ] Phase 5c: cross-agent consistency verified
- [ ] Jira ticket updated with results (if ticket provided)
