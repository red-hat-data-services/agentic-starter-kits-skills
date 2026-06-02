---
name: add-behavioral-tests
description: >-
  Add behavioral testing (pytest + EvalHub) to an agent in the agentic-starter-kits repo.
  Covers runner compatibility, test files, golden queries, thresholds, EvalHub fixture,
  Containerfile, docs, and MLflow tracing verification. Use when implementing
  behavioral tests for a new agent or when the user mentions btest, behavioral tests,
  eval coverage, or test harness integration.
argument-hint: "<agent_path> [JIRA-KEY]"
---
# Add Behavioral Tests to an Agent

End-to-end workflow for adding behavioral testing support to any agent in the agentic-starter-kits repo. Produces pytest behavioral tests + EvalHub fixture + documentation updates. Verifies (but does not set up) MLflow tracing.

**MANDATORY: Every phase and every sub-step in this workflow is a hard requirement.** You MUST complete all phases (0 through 10, plus validation via run-behavioral-tests) and all items in the Definition of Done before reporting the work as complete. No phase may be deferred, skipped, or marked as "infrastructure is in place." If a phase fails, debug and fix it — do not proceed past it until it passes. If a phase is genuinely blocked by an external dependency, stop and notify the user immediately rather than silently skipping it.

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
3. **Document the limitation** in the agent's README testing section (Phase 8 item 5) — note which tests are affected and link the bug ticket.
4. **Continue with the remaining phases** — write the tests against the agent's current behavior. Tests that exercise the buggy path should use realistic thresholds reflecting actual behavior, not aspirational targets.

**No exceptions** — this includes MLflow tracing. If tracing is missing or broken in the agent, log a bug under the parent epic. Do not run `/integrate-tracing` or modify any existing agent source file (`src/`, `main.py`, `Makefile`, `pyproject.toml`, `Containerfile`, tool definitions).

Adding NEW test-only artifacts under the agent directory IS in scope: `tests/behavioral/`, `evalhub/`, and appending a testing section to the agent's README. These do not change agent behavior.

## Input

Arguments: $ARGUMENTS

Parse the arguments to determine:

- **Agent path**: relative to `agents/` (e.g., `crewai/websearch_agent`)
- **Jira key**: optional ticket reference for branch naming and scope

If no agent path is provided, ask the user which agent to add behavioral tests to.

## Phase 0: Gather Context from Jira

Before starting implementation, obtain the Jira ticket(s) for this work.

**If a Jira key is provided in arguments or the user gives one**: Fetch the ticket using the Jira MCP tools (`mcp__jira__jira_get_issue` or `mcp__jira__jira_get_issue_summary`) to extract:

- Scope and acceptance criteria
- Which agent is being tested
- Any parent epic for broader context (e.g. the behavioral testing epic)
- Dependencies or blockers noted in the ticket

**If no ticket is provided**: Ask the user:

1. "What is the Jira ticket key for this work?" (e.g. RHAIENG-XXXX)
2. "Is there a parent epic I should review for context?"

Use the ticket to determine:

- **Agent under test** -- which agent directory
- **Scope boundaries** -- what is in/out for this ticket (no speculative features)
- **Branch naming** -- derive from Jira key: `<JIRA-KEY>/btest-<agent-short-name>`
- **Cluster/environment** -- where tests will run (if specified)

**If Jira MCP tools are unavailable** (no auth, connection failure): ask the user to provide the ticket summary, acceptance criteria, and parent epic key manually. For bug logging (Boundary section), list the bugs that need to be filed in the agent's README testing section (Phase 8 item 5) and ask the user to create them in Jira manually.

Only proceed to Phase 1 once you have a clear ticket and scope.

## Phase 1: Investigate the Agent and Cluster

### Prerequisites

- **`oc` login**: Must be logged into the target cluster. Verify with `oc whoami`. If not logged in, stop and ask the user to authenticate first.

### Cluster inspection

Once logged in, check what's already deployed:

```bash
oc get pods -n <namespace>
oc get routes -n <namespace>
```

Determine:

- Is the agent already deployed? If **not deployed**, deploy it now using `/agentic-starter-kits-skills:deploy-agents <framework>/<agent_name>`. Do NOT defer deployment to Phase 9 — the agent must be running before you proceed to Phase 2 (MLflow tracing verification requires a live agent). Do NOT manually run `make deploy` — see Phase 9 for why `/agentic-starter-kits-skills:deploy-agents` is mandatory.
- What other agents are deployed? (use `helm get values <agent>` to discover cluster-specific config: BASE_URL, MODEL_ID, MLflow vars)
- Is there an MLflow instance? What's the tracking URI?

**Gate**: `agentic-starter-kits-skills:add-behavioral-tests.phase-1-deploy` — consult eval-criteria. If the agent was not already deployed, verify that `/agentic-starter-kits-skills:deploy-agents` was invoked (not manual `make deploy`). This gate checks that the deploy-agents skill's Step 4 (comprehensive MLflow token refresh) ran for all agents in the namespace.

### Agent codebase inspection

Gather these facts:

1. **Agent location**: `agents/<framework>/<agent_name>/`. Check if the agent is non-standard (see AGENTS.md — langflow and a2a agents diverge significantly). If it lacks `main.py`, `src/`, or standard Makefile targets, stop and tell the user that this workflow does not yet support non-standard agents.
2. **Tools available**: Read the agent's tool definitions (MCP server, `@tool` decorators, OpenAI function schemas). If the agent has **no tools** (pure chat agent), skip `test_tool_usage.py` in Phase 4, omit `expected_tools` from golden queries, and waive the `run-behavioral-tests` Phase 2 tool enrichment gate. Focus testing on `test_response_quality.py`, `test_cost_latency.py`, and `test_reliability.py` only.
3. **Response format**: Read the agent's `/chat/completions` handler in `main.py`. Determine if it returns:

   - Standard OpenAI format (`choices[].message.content` + `tool_calls`) -- harness works as-is
   - Custom format (e.g. `messages[]` + `tool_invocations[]`) -- harness needs adaptation
4. **System prompt**: Check if it discourages tool use (e.g. "only call tools if you cannot answer from knowledge"). This affects golden query design.
5. **Streaming mode assessment**: Determine how the agent handles streaming and tool-call exposure. This directly affects whether behavioral tests and EvalHub jobs can extract tool calls reliably.

   **Check these in order:**
   a. Does the agent's `/chat/completions` handler support `stream=true`? (look for SSE/`StreamingResponse` in `main.py`)
   b. When streaming, does it emit tool calls via standard `delta.tool_calls` chunks inside `choices[].delta`? Or does it use custom SSE events (e.g. AutoGen emits `mcp.tool_usage` events outside the OpenAI chunk format)?
   c. When NOT streaming (`stream=false`), does the JSON response body include tool calls — either as `choices[].message.tool_calls` (standard) or `tool_invocations[]` / `context[]` (custom)?

   **Classification:**

   - **Standard streaming** (e.g. LangGraph, vanilla Python): `delta.tool_calls` present in SSE chunks — both `stream=true` and `stream=false` work for tool scoring
   - **Custom streaming** (e.g. AutoGen MCP): tool calls in non-standard SSE events — `stream=false` REQUIRED for reliable tool scoring
   - **No streaming**: agent ignores the `stream` parameter or returns errors — `stream=false` required

   **Default rule**: All behavioral tests and EvalHub fixtures MUST use `stream=false` unless the agent is verified to emit standard `delta.tool_calls` in its SSE stream. The runner's `_run_streaming()` only accumulates `delta.tool_calls` from standard OpenAI-format chunks; custom SSE events are invisible to it, resulting in empty `tool_calls` and failed tool selection scoring.

   Record the agent's streaming classification — it is needed in Phase 6 (EvalHub) and Phase 10 (E2E script).
6. **Makefile deploy target**: Note whether the Makefile exists and has standard targets (`deploy`, `run-app`). MLflow support is checked in detail in Phase 7.

## Phase 2: Verify MLflow Tracing

**Goal**: Confirm that the agent already has MLflow tracing integrated. MLflow tracing is the primary mechanism for extracting tool_calls from agent responses — without it, tool selection tests degrade to content-based heuristics.

Most agents do not expose `tool_calls` in their HTTP response body (the agent runs the full ReAct/Crew loop internally and returns only the final message). Instead, tool calls are captured as `SpanType.TOOL` spans in MLflow traces. The `MLflowTraceClient.enrich_eval_result()` in `evals/harness/mlflow_client.py` extracts these spans into `TaskResult.tool_calls`, which enables the full scorer pipeline (F1 tool selection, hallucinated tools, tool call validity).

### 2a: Check if tracing is already integrated

Look for these indicators in the agent directory:

1. `src/<package>/tracing.py` exists with `enable_tracing()`
2. `main.py` imports and calls `enable_tracing()` in its lifespan
3. `pyproject.toml` has a `tracing` optional dependency group with `mlflow`
4. `Makefile` `run` target includes `$${MLFLOW_TRACKING_URI:+--extra tracing}`

**If all four are present**: tracing is integrated. Proceed to Phase 2b to verify it works.

**If any are missing or broken**: tracing is not integrated. Per the Boundary rule, do NOT modify the agent — log a Jira bug under the parent epic describing which tracing indicators are missing. **Skip Phase 2b entirely** and proceed directly to Phase 3. Tool selection tests will operate in degraded mode (content heuristics only) until tracing is fixed by the agent owner. Document this limitation in the agent's README testing section (Phase 8 item 5).

### 2b: Verify tracing works locally

Start a local MLflow server and confirm traces land correctly:

```bash
cd agents/<framework>/<agent_name>

# Start MLflow server (background)
uv run --extra tracing mlflow server --port 5000 &
MLFLOW_PID=$!

# Start agent with tracing enabled
MLFLOW_TRACKING_URI=http://localhost:5000 \
MLFLOW_EXPERIMENT_NAME=btest-verify \
make run-app &
AGENT_PID=$!

# Wait for agent to be ready
sleep 5
curl -s http://localhost:8000/health
```

Send a test query that triggers tool use:

```bash
curl -s http://localhost:8000/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"<query that triggers a tool>"}],"stream":false}'
```

Verify traces via the MLflow API:

```bash
curl -s http://localhost:5000/api/2.0/mlflow/experiments/get-by-name?experiment_name=btest-verify | python3 -m json.tool
```

Check that:

- An experiment named `btest-verify` was created
- At least one trace exists with spans
- Tool spans appear (span_type="tool") if the agent uses manual tracing (Level B/C)

Clean up:

```bash
kill $AGENT_PID $MLFLOW_PID 2>/dev/null
```

**If verification fails**: diagnose the root cause to include in the Jira bug report. Common causes (check these, note which applies in the bug description):

- `mlflow` not in the agent's `pyproject.toml` `[project.optional-dependencies]`
- `enable_tracing()` not called in the agent's `main.py` lifespan
- Health check timeout too short (try `MLFLOW_HEALTH_CHECK_TIMEOUT=10`)
- Wrong experiment name (env var spelling)

Do not proceed to Phase 3 until traces land successfully. (This only applies when Phase 2a confirmed tracing is integrated — if 2a found tracing missing, 2b is skipped entirely.)

## Phase 3: Runner Compatibility

Check if `evals/harness/runner.py` can parse the agent's response format. The runner has two distinct code paths — which one fires depends on the `stream` config from Phase 1 step 5:

**Non-streaming path** (`stream=false`, the default):

- Sends a regular POST, receives a complete JSON response
- Extracts response text via `_extract_response_text()` — looks for `choices[0].message.content`, then falls back to `messages[]`
- Extracts tool calls via `_extract_tool_calls()` — looks for `choices[].message.tool_calls`, then `context[]`, then `tool_invocations[]`
- This path has the most fallbacks and works with the widest range of agent response formats

**Streaming path** (`stream=true`):

- Sends POST with `"stream": true`, reads SSE chunks via `_run_streaming()`
- Accumulates content from `choices[].delta.content`
- Accumulates tool calls ONLY from `choices[].delta.tool_calls` (standard OpenAI format)
- **No fallbacks for custom SSE events** — if an agent emits tool calls in non-standard events (e.g. AutoGen's `mcp.tool_usage`), they are silently dropped and `tool_calls` will be empty

**Impact on tool scoring**: When `tool_calls` is empty, `score_tool_selection()` falls back to content-based keyword matching instead of F1 scoring — this is unreliable and insufficient for production eval coverage.

**If the agent uses a non-standard non-streaming format**, add additive fallback paths in `runner.py` (this is test infrastructure, not agent code — runner changes are in scope):

- For response text: add a fallback after the `choices[]` check (e.g. `messages[]` with last assistant content)
- For tool calls: add a fallback after the `context[]` check (e.g. `tool_invocations[]`)

Fallbacks must be guarded (only fire when previous methods return nothing) so existing agents are unaffected.

**If the agent's response format is fundamentally broken** (e.g., no content in any recognized field), do NOT modify the agent — log a Jira bug under the parent epic (see Boundary section above) and document the limitation.

## Phase 4: Create Test Files

### Directory structure

```
agents/<framework>/<agent_name>/tests/behavioral/
  conftest.py
  test_tool_usage.py
  test_response_quality.py
  test_cost_latency.py
  test_reliability.py
  test_streaming_parity.py   # only if agent supports standard streaming
  fixtures/
    golden_queries.yaml
```

**If `tests/behavioral/` already exists**: inspect the existing tests before creating anything. If they already cover the required categories and use MLflow enrichment, update them as needed rather than replacing. Preserve any agent-specific customizations and merge new content with existing content.

### conftest.py

Follow the standardized pattern used across all existing agents. Use any existing conftest (e.g. `agents/crewai/websearch_agent/tests/behavioral/conftest.py`) as a reference. The following patterns are mandatory — they must be consistent across ALL agents:

#### Standard patterns (must be consistent across agents)

1. **`_find_repo_root()`**: Must raise `FileNotFoundError` on failure, NOT `pytest.skip()`. Skipping silently hides misconfiguration.

   ```python
   raise FileNotFoundError(
       "Could not find repo root (no tests/behavioral/configs/thresholds.yaml)"
   )
   ```
2. **MLflow enrichment**: Must use `asyncio.to_thread` + `try/except` + WARNING-level logging + `warnings.warn()`. All four elements are required:

   - `asyncio.to_thread` — `enrich_eval_result()` is synchronous; wrapping it avoids blocking the event loop
   - `try/except` — prevents transient MLflow errors from crashing test runs
   - `logging.warning` + `warnings.warn()` — ensures enrichment failure is VISIBLE to both log readers and pytest output. Never use DEBUG level — it silently swallows failures.

   ```python
   if mlflow is not None and result.success:
       try:
           await asyncio.to_thread(
               mlflow.enrich_eval_result, result, since_ms=request_start_ms
           )
       except Exception:
           msg = "MLflow enrichment failed — tool scoring will degrade to content heuristics"
           logging.getLogger(__name__).warning(msg, exc_info=True)
           warnings.warn(msg, stacklevel=2)
   ```
3. **`load_golden()`**: Import from `harness.fixtures` and create a thin 2-line wrapper that binds `fixtures_dir` to `Path(__file__).parent / "fixtures"`. Do NOT deviate from the existing signature `load_golden(category: str | None = None)`.

#### Fixture list

- `agent_url` fixture from `<AGENT_ENV_VAR>` (default `http://localhost:8000`)
- `http_client` async fixture
- `_find_repo_root()` walking up to find `tests/behavioral/configs/thresholds.yaml`
- `eval_config` fixture loading thresholds
- `known_tools` fixture listing the agent's actual tool names
- `<agent>_thresholds` fixture selecting the agent's section from eval_config
- `run_eval` fixture with MLflow trace enrichment (see standard pattern #2 above). This is the PRIMARY mechanism for populating `result.tool_calls`. Without it, tool selection tests fall back to content-based keyword matching — insufficient for production eval coverage.
- Evidence constants appropriate to the agent's domain (must match what the agent actually says in responses, not tool names) — used ONLY as a secondary content check, not as a substitute for tool_calls
- `STREAM` module-level constant: set to `False` by default. Only set to `True` if the agent was classified as "Standard streaming" in Phase 1 step 5 (emits `delta.tool_calls` in standard OpenAI SSE chunks). The `_run()` function must NOT accept `stream` as a parameter — use `stream=STREAM` in TaskConfig instead.
- `load_golden()` thin wrapper importing from `harness.fixtures` and binding `fixtures_dir`

### golden_queries.yaml

Design queries that **will actually trigger tool use** given the agent's system prompt:

- If the prompt discourages tools for knowledge-answerable questions, use explicit tool requests or queries the LLM cannot answer alone
- Include: single-tool, multi-tool (if applicable), no-tool greeting, adversarial
- `expected_elements` should contain the actual expected content (e.g. numeric results, specific data the tool returns)

### Test files

All use `pytestmark = pytest.mark.<agent_marker>`. Follow the vanilla_python or langgraph patterns exactly:

- **test_tool_usage.py**: single/multi tool selection (parametrized from golden), no hallucinated tools, valid args, greeting no-tool
- **test_response_quality.py**: plan coherence, multi-tool synthesis, completeness (parametrized)
- **test_cost_latency.py**: single/multi tool latency against thresholds
- **test_reliability.py** (`pytest.mark.slow`): pass@k for tool selection, multi-tool, response quality
- **test_streaming_parity.py** (only if agent is "Standard streaming" from Phase 1 step 5): sends the same query with `stream=false` and `stream=true`, asserts both produce non-empty content and (when tool_calls are available) the same set of tool names. Uses `run_task` directly with explicit `stream=` in `TaskConfig` — does NOT use the `run_eval` fixture since it hardcodes `STREAM`. See `agents/llamaindex/websearch_agent/tests/behavioral/test_streaming_parity.py` as the reference. Skip this file entirely for agents that use custom SSE events or don't support streaming.

## Phase 5: Config Updates

### tests/behavioral/configs/thresholds.yaml

Add a section for the agent:

```yaml
<agent_key>:
  tool_selection_accuracy: 0.85
  multi_tool_accuracy: 0.75      # only if agent has multi-tool scenarios
  response_coherence_accuracy: 0.75
  max_latency_p95: 15.0
  pass_at_k: 8
```

### Repo-root pyproject.toml

Add marker under `[tool.pytest.ini_options]` markers list in the **repo-root** `pyproject.toml` (not the agent's):

```
"<agent_key>: <Agent Description> (<tool_a> + <tool_b>)",
```

## Phase 6: EvalHub Fixture

### Stream configuration

The EvalHub adapter defaults to `stream=false` (`evals/evalhub_adapter/config.py`). This is intentional — non-streaming JSON responses include tool calls in the body, making tool scoring reliable across all agent types.

**Do NOT set `stream: true`** in the agent's EvalHub fixture or job config unless the agent was classified as "Standard streaming" in Phase 1 step 5 (i.e., it emits `delta.tool_calls` in standard OpenAI SSE chunks). If the agent uses custom SSE events for tool calls, streaming will produce empty `tool_calls` and all tool selection scores will be zero.

When in doubt, leave `stream` unset and rely on the adapter default (`false`).

### Create fixture

`agents/<framework>/<agent_name>/evalhub/tool_use.yaml` -- same schema as existing fixtures:

```yaml
queries:
  - query: "..."
    expected_tools: ["tool_a"]
    expected_elements: ["keyword"]
```

### Update Containerfile

Add COPY line to `evals/evalhub_adapter/Containerfile`:

```dockerfile
COPY agents/<framework>/<agent_name>/evalhub/ ./fixtures/<short_name>/
```

Extend the `RUN` assertion to include the new path.

## Phase 7: Check Makefile MLflow Support

Check if the agent's Makefile `deploy` target has MLflow support (conditional `--set` for `MLFLOW_*` vars). Compare against `agents/langgraph/react_agent/Makefile` as the reference.

**If MLflow deploy support is missing**: do NOT modify the agent's Makefile. Log a Jira bug under the parent epic noting the missing MLflow Helm flags. The agent can still be deployed without MLflow — tracing just won't work on-cluster until the Makefile is updated by the agent owner.

## Phase 8: Documentation Updates

Update these files to reference the new agent:

1. **README.md** -- Add env var row to behavioral tests table
2. **docs/adding-behavioral-tests.md** -- Add to "See existing implementations" lists
3. **docs/adding-evalhub-agent-integration.md** -- Add to "Existing fixtures" list
4. **evals/evalhub_adapter/README.md** -- Update fixture listings, COPY mappings, fixtures_path notes, "What works now"
5. **agents/<framework>/<agent_name>/README.md** -- Add testing section with env var and pytest command

## Phase 9: Verify Agent Deployment

The agent was deployed in Phase 1 via `/agentic-starter-kits-skills:deploy-agents`. This phase verifies the deployment is still healthy before proceeding to validation.

```bash
curl -sf --max-time 10 "https://<agent-route>/health"
```

If the agent is unhealthy or the pod restarted since Phase 1, redeploy using `/agentic-starter-kits-skills:deploy-agents <framework>/<agent_name>`. **ALL deployment MUST go through `/agentic-starter-kits-skills:deploy-agents`** — do NOT manually run `make build`, `make push`, or `make deploy`. The `/agentic-starter-kits-skills:deploy-agents` skill handles cluster config auto-detection, `.env` generation, container build/push, Helm deployment, AND a comprehensive MLflow token refresh across ALL agents in the namespace (Step 4). Manual deployment skips the token refresh, which leaves other agents with stale tokens and breaks MLflow tracing cluster-wide. There is no valid reason to bypass `/agentic-starter-kits-skills:deploy-agents`.

**If deployment fails**: this is a **critical blocker**. Stop and notify the user immediately. Do NOT fall back to local testing — all Phase 11 validation requires a live on-cluster deployment with MLflow tracing. Diagnose the root cause, log a Jira bug under the parent epic, and do not proceed until deployment succeeds.

## Phase 10: Update run-e2e.sh

The E2E script (`evals/evalhub_adapter/tests/run-e2e.sh`) auto-discovers agents and submits EvalHub jobs. It must be updated to include the new agent:

1. **Route discovery**: Add route lookup for the new agent (uses `oc get route` + grep pattern)
2. **Job submission**: Add a submission block that generates a YAML config for the new agent with the correct `fixtures_path` (matching what was COPY'd in the Containerfile)
3. **Results polling**: Ensure the new agent's job is waited on and results reported

Reference the existing agent blocks in the script for the pattern. Each agent needs:

- Route variable (e.g. `AUTOGEN_ROUTE`)
- Generated eval YAML with `model.url`, `parameters.fixtures_path`
- Job submission + poll + result extraction

**Stream parameter in generated YAML**: Do NOT add `stream: true` to the generated eval config unless the agent was classified as "Standard streaming" in Phase 1 step 5. The adapter defaults to `stream=false`, which is correct for most agents. If omitted from the YAML, the default applies.

## Phase 11: Run Validation

Invoke the validation skill to execute all test validation phases:

`/agentic-starter-kits-skills:run-behavioral-tests <agent_path>`

This runs pytest, verifies MLflow traces, executes EvalHub E2E, performs cross-agent consistency checks, and generates the validation report. See the `run-behavioral-tests` skill for full validation details.

## Definition of Done

**MANDATORY — every item below is a hard acceptance requirement.** Do not mark the work complete until ALL items are verified. Do not defer, skip, or report any item as "ready to run later." Each item must be executed and pass during this session.

- [ ]  `tests/behavioral/` directory created with conftest.py, test files, and golden_queries.yaml
- [ ]  `evalhub/tool_use.yaml` fixture created
- [ ]  `evals/evalhub_adapter/Containerfile` updated with COPY line and RUN assertion
- [ ]  `tests/behavioral/configs/thresholds.yaml` updated with agent section
- [ ]  Repo-root `pyproject.toml` updated with pytest marker
- [ ]  `evals/evalhub_adapter/tests/run-e2e.sh` updated with agent blocks
- [ ]  All five documentation files updated (Phase 8 items 1-5)
- [ ]  Any agent bugs found during the process are filed as Jira bugs under the parent epic
- [ ]  Phase 11: Validation completed via `/agentic-starter-kits-skills:run-behavioral-tests`
- [ ]  Jira ticket updated with results summary
