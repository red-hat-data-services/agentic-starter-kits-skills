---
name: deploy-agents
description: Deploy agents to OpenShift with auto-detected cluster config and refresh MLflow tracking tokens.
argument-hint: "<agent_paths or 'all'> [--token-only]"
---

# Deploy Agents to OpenShift

> **Usage:**
> - `/agentic-starter-kits-skills:deploy-agents crewai/templates/websearch_agent` — deploy one agent
> - `/agentic-starter-kits-skills:deploy-agents crewai/templates/websearch_agent langgraph/templates/react_agent` — deploy multiple
> - `/agentic-starter-kits-skills:deploy-agents all` — deploy all standard agents
> - `/agentic-starter-kits-skills:deploy-agents --token-only` — only refresh MLflow tokens, no deployment

You are deploying agents to the agentic-mcp OpenShift cluster. This skill automates cluster config detection, .env generation, container build/push, Helm deployment, and MLflow token refresh.

## Input

Arguments: $ARGUMENTS

Parse the arguments to determine:
- **Target agents**: space-separated paths relative to `agents/` (e.g., `crewai/templates/websearch_agent`), or `all`
- **Token-only mode**: if `--token-only` is present, skip Steps 1–3 and go directly to Step 4

If no arguments are provided, ask the user what to deploy.

> **Gate system**: Pre-conditions and post-conditions are defined in `references/eval-criteria-deploy-validate.json`. The PreToolUse/PostToolUse hooks fire automatically via `scripts/eval-hook.py`.

## Step 0: Validate Prerequisites

Run these checks in parallel. Fail immediately if any required tool is missing.

```bash
oc whoami                # must be authenticated
oc project -q            # capture current namespace — ALL operations scoped here
helm version --short     # must be installed
```

If deploying (not `--token-only`), also check for a container CLI:
```bash
podman version 2>/dev/null || docker version 2>/dev/null
```

If the container CLI is podman, verify the podman machine is running:
```bash
podman machine list --format '{{.Name}}'   # check if any machine exists
```
If no machine is listed, warn the user: "No podman machine found. Run `podman machine init` to create one before deploying."

If a machine exists, check whether it's running:
```bash
podman info >/dev/null 2>&1
```
If `podman info` fails, warn the user: "Podman machine exists but is not running. Start it with `podman machine start` before deploying." Do **not** auto-start the machine — the user may have stopped it intentionally.

**Podman/Docker fallback**: The agent Makefiles auto-detect the container CLI via `command -v podman || command -v docker`. If podman is installed but not running, the Makefile picks podman and fails. When Docker is available as a fallback, pass `CONTAINER_CLI=docker` to all `make build`, `make push`, and `make deploy` commands (e.g., `make build CONTAINER_CLI=docker`). Store whichever CLI is working and use it consistently.

Store the namespace from `oc project -q` — use explicit `-n <namespace>` on every `oc` command for the rest of this workflow. Never rely on the default context.

### 0a: Verify MLflow infrastructure

Check whether the MLflow operator CRD exists (indicates RHOAI 3.5+):
```bash
oc get crd mlflowoperators.components.platform.opendatahub.io 2>/dev/null
```

**If the CRD exists (RHOAI 3.5+)**:

1. Verify the MLflow operator is enabled in the DataScienceCluster:
```bash
oc get datasciencecluster -o json | jq '.items | length'
```
If the count is 0, warn the user: "No DataScienceCluster found — RHOAI may not be installed correctly." If the count is greater than 1, warn: "Multiple DataScienceClusters found — checking the first one, but this is unexpected."

Then check the operator state:
```bash
oc get datasciencecluster -o json | jq '.items[0].spec.components.mlflowoperator.managementState'
```
If it returns `"Removed"`, the MLflow tracking server is **not deployed** — all tracing will fail. Warn the user that `mlflowoperator` must be set to `Managed` in the DataScienceCluster CR before agents can trace.

2. Verify the MLflow pod is running:
```bash
oc get pods -n redhat-ods-applications -l app=mlflow --no-headers 2>/dev/null | grep -c Running
```
If this returns 0, the MLflow tracking server is **not running** — all tracing will fail. Warn the user that the MLflow pod must be running before agents can trace. Check if `mlflowoperator` is set to `Managed` (see check above) and whether the pod is in a non-Running state (CrashLoopBackOff, Pending, etc.).

3. Verify the namespace has the required workspace label. RHOAI 3.5+ requires namespaces to opt in to MLflow tracking via a label. Without it, agents get `RESOURCE_DOES_NOT_EXIST: Workspace '<namespace>' not found ... matches the configured selector ('mlflow-tracking in (enabled)')`.
```bash
oc get namespace <namespace> -o jsonpath='{.metadata.labels.mlflow-tracking}'
```
If the label is missing or not set to `enabled`, apply it:
```bash
oc label namespace <namespace> mlflow-tracking=enabled
```

**If the CRD does not exist (RHOAI < 3.5)**: Skip these checks — the standalone MLflow service is managed differently in older versions and does not require namespace labeling.

> **Gate**: `agentic-starter-kits-skills:deploy-agents.step-0a-mlflow-infra` — consult eval-criteria. Verify MLflow infrastructure is ready.

## Step 1: Resolve Target Agents

If argument is `all`:
1. List all directories under `agents/` (structure: `agents/<framework>/templates/<agent>/`) that contain both `agent.yaml` and a `Makefile`
2. Categorize each agent:
   - **Standard agents**: Makefile references the shared Helm chart (`CHART_DIR` pointing to `../../deployment` or a `helm upgrade` command) → use Steps 3a-3g
   - **Flow-based agents**: `agent.yaml` has `deploymentModel: flow-import` (e.g., `langflow/templates/simple_tool_calling_agent`) → use Step 3-langflow
3. **Skip with warning**: agents that are neither standard nor flow-based (no Helm chart and no `deploymentModel: flow-import`)

If specific paths given:
1. For each path, verify `agents/<path>/agent.yaml` exists (paths can be either `<framework>/<agent>` or `<framework>/templates/<agent>` — resolve both)
2. Check `deploymentModel` in `agent.yaml` — if `flow-import`, route to Step 3-langflow
3. Warn and skip agents that are neither standard nor flow-based

Report the final list of agents to deploy (with their deployment type) before proceeding.

> **Gate**: `agentic-starter-kits-skills:deploy-agents.step-1-resolve` — consult eval-criteria. Verify agent directories (`agents/<framework>/templates/<agent>/`), agent.yaml, Makefile exist; non-standard agents excluded; flow-based agents (langflow) categorized for Step 3-langflow.

## Step 2: Auto-Detect Cluster Config

Detect config from existing deployments in the namespace to avoid asking the user for values they've already configured.

```bash
oc get deployments -n <namespace> -o json
```

From the **first standard agent deployment found**, extract:

| Value | Source |
|---|---|
| `BASE_URL` | env var from deployment spec |
| `MODEL_ID` | env var from deployment spec |
| `API_KEY` | from the deployment's referenced secret (base64-decode) |
| `MLFLOW_TRACKING_URI` | env var from deployment spec |
| `MLFLOW_TRACKING_INSECURE_TLS` | env var from deployment spec |
| `MLFLOW_WORKSPACE` | env var from deployment spec |
| `EMBEDDING_MODEL` | env var from deployment spec (if present — used by RAG agents) |
| `EMBEDDING_DIMENSION` | env var from deployment spec (if present — used by RAG agents) |
| `VECTOR_STORE_PROVIDER` | env var from deployment spec (if present — used by RAG agents) |
| `VECTOR_STORE_ID` | env var from deployment spec (if present — required by RAG agents at runtime) |
| Container image registry prefix | from deployment image spec (e.g., `quay.io/adonheis/`) |

**Do NOT extract `MLFLOW_EXPERIMENT_NAME` from shared config.** Each agent MUST have its own unique experiment name to prevent MLflow trace cross-contamination (see RHAIENG-6743). The experiment name is generated per-agent in Step 3d (Write .env file).

**Security**: Never log, display, or include `API_KEY` or `MLFLOW_TRACKING_TOKEN` values in output. These are sensitive credentials — extract them silently and write them only to `.env` files (which are gitignored).

If **no existing deployments** are found in the namespace, ask the user for all required values.

> **Gate**: `agentic-starter-kits-skills:deploy-agents.step-2-config` — consult eval-criteria. Verify config values extracted and credentials not logged.

## Step 3: Deploy Each Target Agent

Loop over each resolved agent. For each:

### 3a: Check existing deployment
```bash
oc get deployment <agent-name> -n <namespace> 2>/dev/null
```
If it already exists, ask the user whether to redeploy or skip.

### 3b: Read agent requirements
Read `agent.yaml` in the agent directory to discover required env vars. For agents with extra requirements beyond the standard set (e.g., `POSTGRES_*` for db-memory agents, `MCP_SERVER_URL` for autogen agents):
- Use shared config from Step 2 first (`EMBEDDING_MODEL`, `EMBEDDING_DIMENSION`, `VECTOR_STORE_PROVIDER` are commonly shared across RAG agents in the same namespace)
- Try to auto-detect remaining values from an existing deployment of the same agent
- If not found, ask the user

**RAG agents** (labels include `rag` in `agent.yaml`) have additional requirements:
- `VECTOR_STORE_ID` — **required at runtime**. Without it the agent crashes: `"VECTOR_STORE_ID env var is not set"`. Auto-detect from an existing deployment's env vars. If not found, documents must be loaded first (see Step 3d-rag below).
- `DOCS_TO_LOAD` — path to the knowledge base file (defaults to `./data/sample_knowledge.txt`). Only needed if creating a new vector store.

### 3c: Check container image
Check if the container image already exists in the registry:
```bash
podman manifest inspect <registry>/<image>:<tag> 2>/dev/null || skopeo inspect docker://<registry>/<image>:<tag> 2>/dev/null
```
- If image exists: ask whether to rebuild or reuse
- If image doesn't exist or check fails: will build
- Construct the image name from the registry prefix (Step 2) and the agent name from `agent.yaml`

### 3d: Write .env file
Write the `.env` file in the agent directory with:
- All auto-detected config from Step 2
- `MLFLOW_EXPERIMENT_NAME=<namespace>/<deployment-name>` — each agent MUST have a **unique** experiment name to prevent MLflow trace cross-contamination across agents sharing the same namespace. Use the pattern `<namespace>/<deployment-name>`, where `<deployment-name>` is the Kubernetes deployment name (from `metadata.name` in the Helm-generated Deployment resource, which matches the agent directory name). Example: `adonheis-testing/langgraph-react-agent`. Never reuse a single experiment name for multiple agents (RHAIENG-6743).
- Fresh `MLFLOW_TRACKING_TOKEN` from `oc whoami -t`
- `MLFLOW_WORKSPACE` set to the current namespace (`oc project -q`) — **mandatory for OpenShift MLflow**, without it the MLflow API returns "Workspace context is required"
- `MLFLOW_TRACKING_INSECURE_TLS=true` (required when the cluster does not use trusted certificates)
- `CONTAINER_IMAGE` using registry prefix + agent name
- Any agent-specific extra vars from Step 3b

**Never commit .env files** — they are already in `.gitignore`.

### 3d-rag: Load documents into vector store (RAG agents only)

If the agent has the `rag` label in `agent.yaml` and `VECTOR_STORE_ID` is **not set** (no existing vector store found in Step 3b):

1. Run `make load-docs` from the agent directory — this executes `data/load_documents.py` which:
   - Creates a new vector store via OGX using `VECTOR_STORE_PROVIDER` and `EMBEDDING_MODEL`
   - Chunks and embeds documents from `DOCS_TO_LOAD`
   - Writes the new `VECTOR_STORE_ID` back into the agent's `.env` file
2. After `load_documents.py` completes, re-read the `.env` to pick up the generated `VECTOR_STORE_ID`
3. The `VECTOR_STORE_ID` is now baked into the deployment — subsequent deploys auto-detect it from the existing deployment (Step 3b)

If `VECTOR_STORE_ID` **is already set** (auto-detected from an existing deployment), skip this step — the vector store already has documents loaded.

### 3-langflow: Configure flow-based agents

For agents with `deploymentModel: flow-import` in `agent.yaml` (e.g., Langflow), **skip Steps 3a-3g entirely** and use this step instead. Flow-based agents run on a pre-deployed platform instance — there is no container to build or Helm chart to deploy. The skill's job is to configure the flow's model endpoint so it points at the cluster's actual LLM service.

#### 3-langflow-a: Discover Langflow instance

Flow-based agents run in their own namespace. Check `agent.yaml` for a `namespace` field, or default to `langflow-agent`:

```bash
oc get route langflow -n <langflow-namespace> -o jsonpath='{.spec.host}'
```

If no route is found, warn and skip — the Langflow platform is not deployed.

#### 3-langflow-b: Discover flow

List flows on the Langflow instance and match by name:

```bash
curl -sk --compressed "https://<langflow-route>/api/v1/flows/"
```

Parse the JSON response to find flows. If the expected flow exists, capture its `id`. If no flows are found, offer to import the flow JSON from the agent's `flows/*.json` directory via `POST /api/v1/flows/`.

**Note**: Flow IDs are regenerated on each import — always discover by listing, never hardcode.

#### 3-langflow-c: Patch model endpoint

Using `BASE_URL` and `MODEL_ID` from Step 2 (same auto-detected values as standard agents), update the flow's LLM component:

1. Fetch the flow: `GET /api/v1/flows/{flow_id}`
2. Find the KServe/vLLM node in `data.nodes[]` — match on `data.type` containing `KServe` or `VLLM`
3. Update the node's template values:
   - `template.api_base.value` → `BASE_URL` (use the **internal** cluster service URL, not the external route)
   - `template.model_name.value` → `MODEL_ID`
   - `template.api_key.value` → `API_KEY` (or `EMPTY` if the internal endpoint requires no auth)
4. Patch the flow: `PATCH /api/v1/flows/{flow_id}` with `{"data": <updated_flow_data>}`
5. Verify by re-fetching the flow and confirming the values match

**Important**: All `curl` calls to the Langflow API must use `--compressed` — the server returns gzip-encoded responses by default.

#### 3-langflow-d: Verify with test request

Send a test chat request to confirm the flow is functional:

```bash
curl -sk --compressed -X POST "https://<langflow-route>/api/v1/run/<flow_id>" \
  -H "Content-Type: application/json" \
  -d '{"input_value": "Hello", "output_type": "chat", "input_type": "chat"}'
```

- **HTTP 200 with chat response**: Flow is working — report as "configured"
- **HTTP 500 with "Error building Component"**: The model endpoint is unreachable or misconfigured — report the error and suggest checking the model service

> **Gate**: `agentic-starter-kits-skills:deploy-agents.step-3-langflow` — consult eval-criteria. Verify Langflow route discovered, flow found, model endpoint patched, test request succeeded.

### 3e: Build and push (if needed)
If building:
```bash
cd agents/<path>
make build CONTAINER_CLI=<container-cli>
make push CONTAINER_CLI=<container-cli>
```

### 3f: Deploy via Helm
```bash
cd agents/<path>
make deploy CONTAINER_CLI=<container-cli>
```

Where `<container-cli>` is the working container CLI determined in Step 0 (e.g., `docker` or `podman`).

### 3g: Verify health
Wait a few seconds for the pod to start, then:
```bash
# Get the route
oc get route <agent-name> -n <namespace> -o jsonpath='{.spec.host}'
# Health check
# -k disables TLS verification — acceptable for dev/test clusters only
curl -sk https://<route>/health
```

**Note**: `/health` returns `200 OK` even when MLflow tracing is broken — it only checks that the agent process is running. Tracing is verified separately in Step 4f.

If health check fails, check pod status and logs:
```bash
oc get pods -n <namespace> -l app.kubernetes.io/name=<agent-name> --sort-by=.metadata.creationTimestamp
oc logs deployment/<agent-name> -n <namespace> --tail=30
```

Report the result (healthy/unhealthy) and move to the next agent.

> **Gate**: `agentic-starter-kits-skills:deploy-agents.step-3-deploy` and `agentic-starter-kits-skills:deploy-agents.step-3g-health` — consult eval-criteria. Verify .env written, deployment succeeded, health OK.

## Step 4: Refresh MLflow Tokens for ALL Deployed Agents

This step **always runs** — even with `--token-only`, even if no agents were just deployed. It refreshes tokens for every agent in the namespace, not just the ones targeted in this run.

**Flow-based agents (Langflow)** are skipped in Step 4 — they use Langfuse for tracing, not MLflow. They have no MLflow token secrets to refresh.

### 4a: Get fresh token
```bash
TOKEN=$(oc whoami -t)
TOKEN_B64=$(echo -n "$TOKEN" | base64)
```

### 4b: Find all MLflow token secrets
```bash
oc get secrets -n <namespace> -o json | jq -r '.items[] | select(.data["mlflow-tracking-token"] != null) | .metadata.name'
```

### 4c: Patch each secret

**Warning — Helm field ownership**: `oc patch secret` takes field ownership of `.data.mlflow-tracking-token` away from Helm. This causes subsequent `make deploy` (which uses `helm upgrade --install` with server-side apply) to fail with: `conflict with "kubectl-patch" using v1: .data.mlflow-tracking-token`.

For each secret found, update the token while preserving Helm's field ownership:
```bash
oc get secret <secret-name> -n <namespace> -o json \
  | jq ".data[\"mlflow-tracking-token\"]=\"$TOKEN_B64\"" \
  | oc apply --server-side --force-conflicts --field-manager=helm -f -
```

This uses server-side apply with `--field-manager=helm` so Helm retains ownership and future `make deploy` won't conflict. This intentionally impersonates Helm's field manager identity — using a different manager name would re-introduce the conflict. The trade-off is that field ownership audit trails will attribute this change to Helm rather than the skill.

**If you already have a conflict** from a previous `oc patch`: delete the secret (`oc delete secret <secret-name>`) and run `helm uninstall <release>` followed by `make deploy` to do a clean install that restores Helm's field ownership.

### 4d: Restart deployments
For each agent whose token was refreshed:
```bash
oc rollout restart deployment/<agent-name> -n <namespace>
```

### 4e: Verify secretKeyRef wiring is intact

After patching secrets, verify each deployment actually reads the token from the secret (not a hardcoded value). For each agent:

```bash
oc get deployment <agent-name> -n <namespace> -o json | jq '.spec.template.spec.containers[0].env[] | select(.name == "MLFLOW_TRACKING_TOKEN")'
```

**Expected** (correct — reads from secret):
```json
{
  "name": "MLFLOW_TRACKING_TOKEN",
  "valueFrom": { "secretKeyRef": { "name": "<agent>-secret", "key": "mlflow-tracking-token" } }
}
```

**Broken** (hardcoded — secret patch will have no effect):
```json
{
  "name": "MLFLOW_TRACKING_TOKEN",
  "value": "sha256~..."
}
```

If any deployment has a hardcoded `value` instead of `valueFrom.secretKeyRef`, the `secretKeyRef` was overwritten — likely by a previous `oc set env` command. **Fix by redeploying via `make deploy`** from the agent directory (with a fresh token in `.env`). This restores the Helm-managed `secretKeyRef`. Do NOT use `oc set env` to set `MLFLOW_TRACKING_TOKEN` — it replaces the `secretKeyRef` with a plain value.

> **Gate**: `agentic-starter-kits-skills:deploy-agents.step-4-tokens` and `agentic-starter-kits-skills:deploy-agents.step-4e-secretref` — consult eval-criteria. Verify all secrets patched, rollouts restarted, no hardcoded tokens.

### 4f: Verify MLflow connectivity

For each agent, wait for rollout and check startup logs for tracing status:

```bash
oc rollout status deployment/<agent-name> -n <namespace> --timeout=120s
oc logs deployment/<agent-name> -n <namespace> 2>&1 | grep -E "\[Tracing\]|ERROR.*mlflow|ERROR.*crewai"
```

**Healthy** — look for:
```
[Tracing] MLflow server is reachable at ...
[Tracing Enabled] MLflow -> ..., Experiment: ..., LLM Provider: ...
```

**Broken** — look for:
```
[Tracing] Failed to configure MLflow tracing ... Error: Expecting value: line 1 column 1 (char 0)
```
This `JSONDecodeError` means the MLflow API returned a non-JSON response (usually a 302 OAuth redirect because the token is expired/invalid).

Also check for these RHOAI 3.5+ error patterns:
```
RESOURCE_DOES_NOT_EXIST: Workspace '<namespace>' not found ... matches the configured selector ('mlflow-tracking in (enabled)')
```
Fix: the namespace needs the `mlflow-tracking=enabled` label — see Step 0a.

```
401 {"error_code":"UNAUTHENTICATED","message":"Authentication to the MLflow tracking server failed..."}
```
Fix: the MLflow operator is not deployed or the tracking server is not running — see Step 0a.

To confirm, test the token directly against the MLflow API:
```bash
TOKEN=$(oc get secret <agent-name>-secret -n <namespace> -o jsonpath='{.data.mlflow-tracking-token}' | base64 -d)
MLFLOW_URI=$(oc get deployment <agent-name> -n <namespace> -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MLFLOW_TRACKING_URI")].value}')
curl -sk -H "Authorization: Bearer $TOKEN" "$MLFLOW_URI/api/3.0/mlflow/server-info"
```
- **JSON response** (`{"store_type":"SqlStore",...}`) means the token is valid
- **302 redirect / HTML** means the token is expired — refresh via Step 4a-4d

Verify health as in Step 3g. Remember that `/health` returns `200 OK` even when tracing is broken — always check the startup logs for `[Tracing Enabled]` to confirm tracing is working.

> **Gate**: `agentic-starter-kits-skills:deploy-agents.step-4f-mlflow` — consult eval-criteria. Verify rollouts complete, tracing enabled in logs, no JSONDecodeError.

## Step 5: Summary Report

Print a summary table:

```
Agent                                              | Status      | Route                                    | Health | Token
---------------------------------------------------|-------------|------------------------------------------|--------|--------
crewai/templates/websearch_agent                   | deployed    | websearch-agent-agentic-mcp.apps.xxx     | OK     | refreshed
langgraph/templates/react_agent                    | redeployed  | react-agent-agentic-mcp.apps.xxx         | OK     | refreshed
langgraph/templates/human_in_the_loop              | skipped     | hitl-agent-agentic-mcp.apps.xxx          | OK     | refreshed
langflow/templates/simple_tool_calling_agent       | configured  | langflow-langflow-agent.apps.xxx         | OK     | n/a (Langfuse)
autogen/templates/mcp_agent                        | failed      | —                                        | —      | —
```

If any agents failed, show the failure reason and suggest next steps.

> **Gate**: `agentic-starter-kits-skills:deploy-agents.post` — consult eval-criteria. Verify all steps completed and summary was generated.

## Troubleshooting: MLflow Tracing Not Working on Agents

### Symptom: Agent logs show `Expecting value: line 1 column 1 (char 0)`

**Cause**: The `MLFLOW_TRACKING_TOKEN` is expired or invalid. The MLflow API returns a 302 redirect instead of JSON. See Step 4f for full diagnosis (including direct `curl` test) and Step 4a-4d for the fix. If the deployment has a hardcoded token instead of `secretKeyRef`, see Step 4e.

### Symptom: `RESOURCE_DOES_NOT_EXIST: Workspace '<namespace>' not found`

**Cause** (RHOAI 3.5+): The namespace is missing the `mlflow-tracking=enabled` label. MLflow workspaces map 1:1 to namespaces, and only namespaces with this label are recognized. See Step 0a for the fix.

### Symptom: `401 UNAUTHENTICATED` with message about `MLFLOW_TRACKING_AUTH=kubernetes-namespaced`

**Cause** (RHOAI 3.5+): The MLflow operator is not deployed, or the MLflow tracking server is not running. The external route serves the RHOAI dashboard frontend (HTML) instead of the MLflow API. Check:
1. `oc get datasciencecluster -o json | jq '.items[0].spec.components.mlflowoperator'` — must be `Managed`, not `Removed`
2. `oc get pods -n redhat-ods-applications | grep mlflow` — MLflow pod must exist and be Running
3. If `mlflowoperator` is `Removed`, it needs to be enabled in the DataScienceCluster CR

### Symptom: `make deploy` fails with `conflict with "kubectl-patch"`

**Cause**: A previous `oc patch secret` command took field ownership of `.data.mlflow-tracking-token` away from Helm. Helm's server-side apply refuses to overwrite fields owned by another manager.

**Fix**: Delete the conflicting secret and Helm release, then reinstall:
```bash
oc delete secret <agent-name>-secret -n <namespace>
helm uninstall <agent-name> -n <namespace>
make deploy   # clean install restores Helm field ownership
```

See Step 4c for the correct patching approach that avoids this conflict.

### Symptom: Secret patched but agent still uses old token

**Cause**: The deployment's `MLFLOW_TRACKING_TOKEN` env var is a hardcoded `value` instead of a `valueFrom.secretKeyRef`. See Step 4e for full diagnosis and fix.

### Symptom: Behavioral tests skip with "tool_calls not exposed"

**Cause**: The agent is not producing MLflow traces, so the test harness's `MLflowTraceClient` finds nothing. This is almost always a token issue (see above). The `/health` endpoint returns `200 OK` regardless of tracing status, so health checks won't catch this.

**Diagnosis**:
1. Check agent startup logs for `[Tracing Enabled]` vs `[Tracing] Failed to configure`
2. If tracing is enabled, check MLflow for recent traces from the agent
3. If traces exist but have no TOOL spans, that's a separate issue (see RHAIENG-5069)

## Key Constraints

- **Namespace isolation**: All `oc` commands use explicit `-n <namespace>`. Never touch resources outside the current namespace.
- **No chart modifications**: Never modify the shared Helm chart in `agents/<framework>/deployment/` templates.
- **No .env commits**: `.env` files are written but never staged or committed.
- **Token refresh is comprehensive**: Step 4 covers ALL agents in the namespace, not just targets.
- **Ask before destructive actions**: Always confirm before redeploying an existing agent or rebuilding an image.
