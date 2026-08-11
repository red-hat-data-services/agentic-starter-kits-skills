---
name: run-behavioral-tests
description: >-
  Run and validate behavioral tests (pytest + EvalHub E2E) for an agent in the
  agentic-starter-kits repo. Executes pytest with MLflow enrichment, verifies
  trace structure, runs EvalHub E2E, cross-agent consistency check, and generates
  a validation report. Use when running behavioral tests, validating btest setup,
  or re-running validation after fixes.
argument-hint: "<agent_path>"
---
# Run Behavioral Tests for an Agent

Validation workflow for behavioral tests in the agentic-starter-kits repo. This skill executes and validates behavioral tests (pytest + EvalHub E2E) for an agent whose test scaffolding has already been created by the `add-behavioral-tests` skill (Phases 0-10). It runs pytest with MLflow trace enrichment, verifies trace structure, runs EvalHub E2E jobs, performs cross-agent consistency checks, and generates a validation report.

**MANDATORY: Every phase and every sub-step in this workflow is a hard requirement.** You MUST complete all phases (1 through 11) and all items in the Definition of Done before reporting the work as complete. No phase may be deferred, skipped, or marked as "infrastructure is in place." If a phase fails, debug and fix it — do not proceed past it until it passes. If a phase is genuinely blocked by an external dependency, stop and notify the user immediately rather than silently skipping it.

## Boundary: Do NOT modify the agent under test

The agent's source code (`src/`, `main.py`, tool definitions, system prompt, response handlers) is **out of scope** for this workflow. Behavioral tests observe the agent as-is — they do not fix, improve, or adapt the agent to make tests pass.

If you discover a bug or deficiency in the agent during any phase (e.g., tool calls not exposed in responses, broken streaming, incorrect tool behavior, missing error handling):

1. **Do NOT fix it in the agent code.** The agent is owned separately and changes require their own review.
2. **Log a Jira bug** under the **parent epic** of the current behavioral-testing ticket. Use `mcp__jira__jira_get_issue` on the current ticket to find the parent epic, then create the bug with `mcp__jira__jira_create_issue`:
   - Project key: same as the current ticket
   - Issue type: Bug
   - Summary: clear description of the deficiency
   - Parent: the parent epic key
   - Description: what was observed, expected behavior, and which phase of btest work uncovered it
   - Label: `behavioral-tests`
3. **Document the limitation** in the agent's README testing section — note which tests are affected and link the bug ticket.
4. **Continue with the remaining phases** — write the tests against the agent's current behavior. Tests that exercise the buggy path should use realistic thresholds reflecting actual behavior, not aspirational targets.

**No exceptions** — this includes MLflow tracing. If tracing is missing or broken in the agent, log a bug under the parent epic. Do not run `/integrate-tracing` or modify any existing agent source file (`src/`, `main.py`, `Makefile`, `pyproject.toml`, `Containerfile`, tool definitions).

Adding NEW test-only artifacts under the agent directory IS in scope: `tests/behavioral/`, `evalhub/`, and appending a testing section to the agent's README. These do not change agent behavior.

## Input

Arguments: $ARGUMENTS

Parse the arguments to determine:

- **Agent path**: relative to `agents/` (e.g., `crewai/templates/websearch_agent`, `google/templates/adk`)

If no agent path is provided, ask the user which agent to run behavioral tests for.

## Pre-flight: Verify Scaffolding Phases (0-10) Complete

Before running validation, confirm that all scaffolding artifacts from the `add-behavioral-tests` skill exist. These checks correspond to the outputs of Phases 0-10.

> **Gate system**: Gates are defined in `references/eval-criteria-run-btest-validate.json`. The `pre` gate fires automatically via PreToolUse hooks. Mid-execution gates (`phase-1` through `phase-10`) are evaluated inline at each sub-phase boundary — read the criteria file and verify all checks pass before proceeding.

**Procedure**: For MLflow checks, run `mlflow-procedures.json: check-token-validity` first, then `mlflow-procedures.json: get-experiment-id`. If either fails, MLflow is not reachable — do not proceed to Phase 1.

Verify ALL of the following:

1. **`oc` auth**: `oc whoami` succeeds (logged into OpenShift cluster)
2. **`oc` token**: `oc whoami -t` returns a valid token (not expired)
3. **Test directory**: `agents/${AGENT_PATH}/tests/behavioral/conftest.py` exists (Phase 4 complete)
4. **Golden queries**: `agents/${AGENT_PATH}/tests/behavioral/fixtures/golden_queries.yaml` exists (Phase 4 complete)
5. **EvalHub fixture**: `agents/${AGENT_PATH}/evalhub/tool_use.yaml` exists (Phase 6 complete)
6. **Containerfile**: `evals/evalhub_adapter/Containerfile` contains COPY line for agent (Phase 6 complete)
7. **Thresholds**: `tests/behavioral/configs/thresholds.yaml` has agent section (Phase 5 complete)
8. **E2E script**: `evals/evalhub_adapter/tests/run-e2e.sh` updated with agent blocks (Phase 10 complete)
9. **Pytest runner script**: `tests/behavioral/deterministic/run-btests-pytest.sh` AGENTS array includes the agent (Phase 5 complete)
10. **Shared conftest**: `tests/behavioral/conftest.py` `_AGENT_URL_MAP` includes the agent marker (Phase 5 complete)
11. **Agent health**: Agent deployed and reachable (health endpoint returns OK)
12. **MLFLOW_TRACKING_URI**: Set to the cluster MLflow instance
13. **MLFLOW_EXPERIMENT_NAME**: Set to the agent's **per-agent** experiment name (e.g., `<namespace>/<deployment-name>`). Each agent MUST have a unique experiment name — a shared name causes trace cross-contamination (RHAIENG-6743). The `run-btests-pytest.sh` script auto-detects per-agent experiment names from each deployment.
14. **MLFLOW_WORKSPACE**: Set to the OpenShift namespace (same as `oc project -q`)
15. **MLFLOW_TRACKING_INSECURE_TLS**: Set to `true` for OpenShift clusters with self-signed certs
16. **Agent URL env var**: Agent-specific URL env var (e.g. `CREWAI_WEBSEARCH_AGENT_URL`, `GOOGLE_ADK_AGENT_URL`) is set and points to the deployed OpenShift route
17. **Agent pod MLflow tokens valid**: For each agent under test, check the pod startup logs for `[Tracing Enabled]` vs `[Tracing] Failed to configure`. If ANY agent shows tracing failures (e.g. `Expecting value: line 1 column 1 (char 0)` — the classic expired-token symptom), the tokens are expired and MUST be refreshed before proceeding.

### Mandatory: Refresh MLflow tokens before testing

**BLOCKING — do this before Phase 1, every time.** OpenShift tokens expire frequently and behavioral tests depend on MLflow trace enrichment. Do NOT assume tokens are valid just because the agent health endpoint returns 200 — `/health` succeeds even when tracing is completely broken.

Run the `deploy-agents` skill in token-only mode to refresh all agent tokens:

```
/agentic-starter-kits-skills:deploy-agents --token-only
```

This refreshes `MLFLOW_TRACKING_TOKEN` secrets for ALL deployed agents, restarts rollouts, and verifies tracing is working (Step 4 of deploy-agents). Wait for all rollouts to complete and confirm `[Tracing Enabled]` appears in each agent's startup logs before proceeding to Phase 1.

If any check fails, stop and report which pre-flight check failed. Do not proceed to Phase 1.

## Phase 1: Pytest behavioral tests (with MLflow trace enrichment)

MLflow env vars are REQUIRED for behavioral tests — without them, tool_calls cannot be extracted from traces and tool selection tests degrade to weak content heuristics.

**IMPORTANT: Run from the repo root directory** (`agentic-starter-kits/`), not from the agent directory. The test dependencies (`pytest-asyncio`, `harness` package) are declared in the **root** `pyproject.toml` under `[project.optional-dependencies] test`, not in agent-level `pyproject.toml` files. Running from an agent directory uses the agent's venv which lacks these deps and fails with `PytestRemovedIn9Warning: requested an async fixture with no plugin that handled it`.

```bash
# MUST run from repo root
cd /path/to/agentic-starter-kits

# Collect tests (verify discovery)
uv run --extra test --extra test-mlflow pytest agents/<framework>/<agent_name>/tests/behavioral/ --collect-only

# Run against live agent with MLflow enabled (ALL six env vars required for OpenShift MLflow)
<AGENT_ENV_VAR>=https://<route> \
MLFLOW_TRACKING_URI=<uri> \
MLFLOW_EXPERIMENT_NAME=<namespace>/<deployment-name> \
MLFLOW_TRACKING_TOKEN=$(oc whoami -t) \
MLFLOW_WORKSPACE=<namespace> \
MLFLOW_TRACKING_INSECURE_TLS=true \
uv run --extra test --extra test-mlflow pytest agents/<framework>/<agent_name>/tests/behavioral/ -v
```

**`MLFLOW_WORKSPACE` is mandatory for OpenShift MLflow** — without it the MLflow API returns `INVALID_PARAMETER_VALUE: Workspace context is required for this request`. Set it to the OpenShift namespace (e.g. the value from `oc project -q`).

All tests must pass.

**Gate**: `agentic-starter-kits-skills:run-behavioral-tests.phase-1` — consult eval-criteria.

## Phase 1b: Run full behavioral test suite via run-btests-pytest.sh

Run the deterministic test runner script that executes ALL agents' behavioral tests in parallel. This validates that the new agent integrates correctly into the multi-agent test pipeline and that the `AGENTS` array and `_AGENT_URL_MAP` are in sync.

```bash
cd tests/behavioral/deterministic
./run-btests-pytest.sh <framework>/<agent_name>
```

To run only the agent under test, pass the agent path as an argument (e.g. `langgraph/templates/human_in_the_loop`). To run all agents: `./run-btests-pytest.sh` with no arguments.

The script:
1. Pre-flight validates `oc` auth, `uv`, and that the AGENTS array is in sync with `conftest._AGENT_URL_MAP`
2. Auto-discovers agent routes from OpenShift
3. Detects MLflow config from existing deployments
4. Runs each agent's `tests/behavioral/` in parallel with MLflow env vars
5. Collects results and prints a summary table with detailed breakdown

All agents must pass. If the agent under test fails, investigate before proceeding. If OTHER agents fail, determine whether the failure is pre-existing or related to changes made in this session.

**Gate**: `agentic-starter-kits-skills:run-behavioral-tests.phase-1b` — consult eval-criteria.

## Phase 2: Verify tool_calls came from MLflow traces (GATE — blocks completion)

This is a **hard gate**, not a soft check. Tests passing without MLflow enrichment is a FAILURE — it means tool selection scoring fell back to unreliable content heuristics, giving a false sense of coverage. Do not mark the work as complete if this gate fails.

**Waiver**: If Phase 2a (from `add-behavioral-tests`) determined that tracing is missing/broken and a Jira bug was filed, this gate is waived. Document in the agent's README testing section that tool scoring is operating in degraded mode (content heuristics only), reference the bug ticket, and note the expected behavior once tracing is fixed. The gate only blocks when tracing is expected to work but enrichment fails at runtime.

After the test run, confirm that `MLflowTraceClient.enrich_eval_result()` successfully extracted tool_calls from MLflow trace spans:

1. **Check test output for warnings**: Look for both the "tool_calls not exposed in response" warning (from test code) AND the "MLflow enrichment failed" warning (from conftest). Either one means enrichment did not work.
2. **Confirm scorer execution**: The tool selection tests should have run `score_tool_selection()` (F1 scoring), `score_hallucinated_tools()`, and `score_tool_call_validity()` — not just content keyword matching.
3. **If ANY enrichment warning is emitted**, enrichment failed. Debug:

   - Both `MLFLOW_TRACKING_URI` and `MLFLOW_EXPERIMENT_NAME` must be set (both required for `MLflowTraceClient` to initialize)
   - Agent pod must have a valid `MLFLOW_TRACKING_TOKEN` (not expired)
   - MLflow must be reachable from the agent pod: `oc exec deployment/<agent-name> -- curl -s <uri>/health`
   - Traces must exist in the experiment — query: `curl -s "${MLFLOW_TRACKING_URI}/api/2.0/mlflow/experiments/get-by-name?experiment_name=<experiment>"`
   - Tool spans must have `SpanType.TOOL` — the extraction uses `"TOOL" in str(span_type).upper()` which matches standard MLflow span types from both autolog and `wrap_func_with_mlflow_trace()`

**Gate**: `agentic-starter-kits-skills:run-behavioral-tests.phase-2` — consult eval-criteria. **HARD GATE — blocks completion.**

## Phase 3: Verify MLflow trace structure

Use the `inspect-span-types` procedure from `references/mlflow-procedures.json`. This is the **only** way to verify trace structure — do not use ad-hoc curl commands or invent alternative approaches.

The procedure queries the MLflow API, fetches the latest trace, and prints the full span tree with types, names, and parent relationships. Run it exactly as written.

Confirm these span types appear in the output:

- `[TOOL]` spans with names matching the agent's tool names
- `[CHAT_MODEL]` spans with `tokenUsage` values
- Framework spans: `[CHAIN]` for LangGraph/LangChain, `[AGENT]` for CrewAI/Google ADK, `[RETRIEVER]` for RAG agents
- Parent/child relationships — not all spans at `parent=ROOT`

If tool spans are missing, check whether tracing is actually enabled in the agent (Phase 2a indicators). If tracing is integrated but tool spans are absent, the tracing wiring may be incomplete — log a bug under the parent epic.

**Gate**: `agentic-starter-kits-skills:run-behavioral-tests.phase-3` — consult eval-criteria.

## Phase 4: Check agent pod logs

```bash
oc logs deployment/<agent-name> -n <namespace> --tail=50
```

Look for:

- MLflow connection errors or auth failures
- Tracing initialization messages
- Any warnings about span creation failures

**Gate**: `agentic-starter-kits-skills:run-behavioral-tests.phase-4` — consult eval-criteria.

## Phase 5: Run EvalHub E2E job

Run the full E2E script to validate the EvalHub integration end-to-end:

```bash
cd evals/evalhub_adapter/tests
./run-e2e.sh
```

This must:

- Discover the new agent's route
- Build/push the updated adapter image (with the new COPY'd fixture)
- Register the provider
- Submit eval jobs for ALL agents (including the new one)
- Poll until completion
- Report results with non-null scores

Verify the new agent's job completes with `state: completed` and scores are reasonable. Failures in other agents' jobs that are unrelated to tracing may be pre-existing, but `mlflow_run_id: null` is NEVER pre-existing — it is always a FAIL.

**Gate**: `agentic-starter-kits-skills:run-behavioral-tests.phase-5` — consult eval-criteria.

## Phase 6: Verify E2E MLflow enrichment

After the E2E run, verify that MLflow enrichment worked — this mirrors Phase 2 but for the EvalHub-orchestrated run. Use procedures from `references/mlflow-procedures.json`:

1. **Run `count-traces-since`** to verify new traces were created during the E2E run. Compare trace count before vs after.
2. **mlflow_run_id must be non-null** for ALL agents' eval results. A null `mlflow_run_id` means the agent did not produce a trace — this is a FAILURE regardless of which agent produced it. Debug with: `oc get deployment/<agent> -o jsonpath='{.spec.template.spec.containers[0].env}'` to check MLflow env vars on the pod.
3. **No enrichment failures**: Check E2E script output for "MLflow enrichment failed" or "enrichment error".
4. **tool_calls populated**: Tool selection scores > 0 for queries with expected_tools. All-zero scores mean enrichment failed silently.

**Gate**: `agentic-starter-kits-skills:run-behavioral-tests.phase-6` — consult eval-criteria.

## Phase 7: Verify E2E MLflow trace structure

Inspect MLflow traces created during the E2E run — this mirrors Phase 3. Run the `inspect-span-types` procedure from `references/mlflow-procedures.json`. Same procedure as Phase 3, same expected output:

- `[TOOL]` spans with agent tool names
- `[CHAT_MODEL]` spans with `tokenUsage`
- Framework spans (`[CHAIN]`/`[AGENT]`/`[RETRIEVER]`)
- Parent/child nesting (not all `parent=ROOT`)

**Gate**: `agentic-starter-kits-skills:run-behavioral-tests.phase-7` — consult eval-criteria.

## Phase 8: Check agent pod logs after E2E

Inspect agent pod logs after the E2E run — this mirrors Phase 4.

```bash
oc logs deployment/<agent-name> -n <namespace> --tail=50
```

Look for:

- MLflow connection errors or auth failures
- Tracing activity during the E2E run window
- Span creation failures
- Unhandled exceptions related to MLflow or tracing

**Gate**: `agentic-starter-kits-skills:run-behavioral-tests.phase-8` — consult eval-criteria.

## Phase 9: Inspect EvalHub adapter container

Verify the adapter container is correctly configured for the new agent:

1. **Fixture present**: `oc exec deployment/evalhub-adapter -- ls fixtures/<agent_short>/tool_use.yaml`
2. **Fixture parseable**: No YAML errors in adapter logs related to the agent's fixture
3. **Provider registered**: EvalHub API lists the agent with correct route URL
4. **Scoring config**: `stream=false` unless agent is "Standard streaming"
5. **Adapter logs clean**: No errors for this agent (connection, scoring, timeout)
6. **MLflow connectivity**: Adapter can reach MLflow for trace enrichment

**Gate**: `agentic-starter-kits-skills:run-behavioral-tests.phase-9` — consult eval-criteria.

## Phase 10: Cross-agent Implementation Consistency Check

Read the full behavioral test implementation of ALL existing agents (`agents/*/templates/*/tests/behavioral/`) and verify the new agent is consistent across every layer. If ANY existing agent deviates, fix it in this PR.

**conftest.py:**

1. `_find_repo_root()` raises `FileNotFoundError`, not `pytest.skip()`
2. MLflow enrichment uses `asyncio.to_thread` + `try/except` + `logging.warning()` + `warnings.warn()` — all four elements
3. `load_golden()` function body is identical across agents
4. Import block has stdlib separated from third-party (ruff I001)
5. `run_eval` has the same parameter list across agents (`stream` must NOT be a parameter — it must be a `STREAM` module-level constant used in TaskConfig)

**Test files:**
6. Same four test files exist (plus `test_streaming_parity.py` if agent supports standard streaming)
7. Each uses `pytestmark = pytest.mark.<agent_marker>`; reliability also includes `pytest.mark.slow`
8. Scorer imports are consistent
9. Core test functions match the existing pattern
10. All test functions use the `run_eval` fixture — no direct HTTP calls (exception: `test_streaming_parity.py` uses `run_task` directly since it needs explicit `stream=` control)

**Fixtures:**
11. `golden_queries.yaml` standard schema: `query`, `expected_tools`, `expected_elements`, `difficulty`, `category`
12. `evalhub/tool_use.yaml` standard schema: `query`, `expected_tools`, `expected_elements`

**Config:**
13. `thresholds.yaml` agent section has the same keys as other agents

**Gate**: `agentic-starter-kits-skills:run-behavioral-tests.phase-10` — consult eval-criteria.

## Phase 11: Generate Validation Report

After all Phase 1-10 gates have been evaluated, generate a validation report. The PostToolUse hook emits a report template (`<eval-report>`) — use it as the structure.

Write the completed report to: `tests/behavioral/reports/BTEST_VALIDATION_REPORT_<agent_name>.md`

For every assertion:

- `[PASS]` — verified and succeeded
- `[FAIL]` — verified and failed
- `[WAIVED]` — waiver condition met (with Jira bug reference)
- `[SKIPPED]` — not applicable

Fill in all summary sections (MLflow Trace Summary, EvalHub E2E Summary, Bugs Filed). This report is a permanent record and should be committed alongside the test artifacts.

## Definition of Done

**MANDATORY — every item below is a hard acceptance requirement.** Do not mark the work complete until ALL items are verified. Do not defer, skip, or report any item as "ready to run later." Each item must be executed and pass during this session.

- [ ]  Phase 1: all pytest behavioral tests pass
- [ ]  Phase 1b: run-btests-pytest.sh passes for the agent under test
- [ ]  Phase 2: tool_calls enrichment gate passed (or waived with bug ticket if tracing is missing)
- [ ]  Phase 3: MLflow trace structure verified
- [ ]  Phase 4: Agent pod logs clean
- [ ]  Phase 5: EvalHub E2E job completes with reasonable scores
- [ ]  Phase 6: E2E MLflow enrichment verified (mlflow_run_id non-null for all agents)
- [ ]  Phase 7: E2E MLflow trace structure verified
- [ ]  Phase 8: Agent pod logs clean after E2E
- [ ]  Phase 9: EvalHub adapter container inspection passed
- [ ]  Any agent bugs found during the process are filed as Jira bugs under the parent epic
- [ ]  Phase 10: Cross-agent consistency check passed (13-point verification)
- [ ]  Phase 11: Validation report generated and committed
- [ ]  Jira ticket updated with results summary
