---
name: fit-check
description: >-
  Validate whether a new agent template or example belongs in the
  agentic-starter-kits repo. Two modes: idea mode (interactive questionnaire,
  no code yet) or existing agent mode (auto-extract from code). Produces a
  GitHub Discussion draft with fit score and recommendations. Use when
  proposing a new agent, reviewing an existing contribution's fit, or before
  writing code for a new template.
argument-hint: "[agent_path]"
---
# Agent Fit Check

Validates whether a proposed or existing agent belongs in the agentic-starter-kits repo. Every agent in this repo must complete the sentence:

> "As an AI engineer, I need to know how to build an agent using **\_\_\_\_\_** and integrate it with these RHOAI components: **\_\_\_\_\_** for **\_\_\_\_\_**"

The skill collects answers to 6 dimensions, scores them against the repo's standards, and produces a GitHub Discussion draft for maintainer review.

## Input

Arguments: $ARGUMENTS

Parse the arguments to determine:

- **Agent path** (optional): relative to `agents/` (e.g., `langgraph/templates/my_agent`). Paths starting with `agents/` are normalized by stripping the prefix.
- If an agent path is provided: enter **existing agent mode** (auto-extract from code).
- If no argument is provided: enter **idea mode** (interactive questionnaire).

## Phase 0: Validate Prerequisites

1. Confirm the working directory is the agentic-starter-kits repo root — check that `AGENTS.md` exists. If not, stop and tell the user to `cd` into the repo.
2. In existing agent mode: verify `agents/<agent_path>/` exists. If not, list available agent directories and ask the user to pick one.

## Phase 1: Collect Answers

This phase populates 6 dimensions. The method depends on the mode but the output structure is identical.

### Idea mode — interactive questionnaire

Ask the contributor these questions **one at a time** (each answer may inform the next question):

1. **Framework/platform**: "Which agent framework will you use?"
   - Offer the existing frameworks as options: LangGraph, CrewAI, AutoGen, LlamaIndex, Google ADK, Langflow, vanilla Python (OpenAI SDK)
   - Also offer "A new framework not yet in the repo" — if selected, ask for the framework name

2. **Template or example**: "Is this a template or an example?"
   - Template = reusable, general-purpose agent that demonstrates a framework + RHOAI integration pattern
   - Example = business use-case demo built on top of a template (e.g., customer support bot, code reviewer)

3. **RHOAI components and purpose**: "Which RHOAI components will this agent integrate with, and for what purpose?"
   - Present as a multi-select with purpose descriptions:
     - OGX/vLLM — for LLM inference
     - MLflow — for tracing/observability
     - Milvus — for vector search (RAG)
     - PostgreSQL — for persistent conversation memory
     - MCP servers — for dynamic tool loading
     - Other (ask them to specify the component and purpose)
   - At minimum, OGX/vLLM for inference should be present. If omitted, flag it.

4. **Differentiation**: "What new capability does this agent demonstrate that the existing agents do not cover?"
   - Before asking, list the existing agents (name + one-line description from agent.yaml) so the contributor can see what already exists.
   - The answer should explain what an AI engineer would learn from this template that they cannot learn from the existing ones.

5. **API contract**: "Will the agent conform to the standard API contract?"
   - Standard = POST /chat/completions (JSON + SSE) and GET /health returning `{"status": "healthy", "agent_initialized": true}`
   - If no: ask what the alternative is (e.g., flow-import deployment model, different protocol)

6. **Container pattern**: "Will the agent use the standard container pattern?"
   - Standard = UBI9 Python 3.12 base image (`registry.access.redhat.com/ubi9/python-312`), port 8080, non-root UID 1001
   - If no: ask what the alternative is

### Existing agent mode — auto-extraction

Read files from `agents/<agent_path>/` and extract answers programmatically:

**1. Framework:**

- Primary: read `agent.yaml` field `framework`
- Fallback: derive from directory path (first segment under `agents/`)
- If neither exists: classify as "unknown framework"

**2. Template or example:**

- Determine from directory path — presence of `templates/` or `examples/` in the path
- If neither: flag as "non-standard location"

**3. RHOAI components and purpose:**

Extract from multiple sources and merge:

| Source | What to extract |
|--------|----------------|
| `agent.yaml` `env.required` + `env.optional` | Map env var names to components (see mapping below) |
| `.env.example` | Scan for component-related env vars (including commented-out ones) |
| `pyproject.toml` dependencies | Check for `milvus`, `pymilvus`, `psycopg`, `mlflow`, `mcp` packages |
| `Dockerfile` / `docker-compose.yaml` | Check for service dependencies |

Env var to component mapping:

| Env var pattern | Component | Purpose |
|----------------|-----------|---------|
| `BASE_URL`, `MODEL_ID`, `API_KEY` | OGX/vLLM | LLM inference |
| `MLFLOW_*` | MLflow | Tracing/observability |
| `POSTGRES_*` | PostgreSQL | Persistent memory |
| `MILVUS_*`, `VECTOR_STORE_*`, `EMBEDDING_*` | Milvus | Vector search (RAG) |
| `MCP_SERVER_URL`, `MCP_*` | MCP servers | Dynamic tool loading |
| `LANGFUSE_*` | Langfuse | Observability (non-standard) |
| `OLLAMA_*` or ollama references | Ollama | Local inference (non-standard) |

**4. Differentiation:**

- Read `agent.yaml` `description` field as the raw input
- Read `README.md` first paragraph for additional context
- This is compared against existing agents in Phase 2

**5. API contract:**

Check `main.py` for:

- `POST /chat/completions` route (grep for `"/chat/completions"` or `@app.post`)
- `GET /health` route (grep for `"/health"` or `@app.get`)
- SSE streaming support (`StreamingResponse`, `text/event-stream`)
- If no `main.py`: check for `deploymentModel: flow-import` in `agent.yaml` (accepted alternative)
- If no main.py and no flow-import: flag as non-standard

**6. Container pattern:**

Check `Dockerfile` for:

- UBI9 base image: grep for `registry.access.redhat.com/ubi9/python-312`
- Port 8080: grep for `EXPOSE 8080`
- Non-root UID 1001: grep for `USER 1001`
- If no `Dockerfile`: flag as non-standard (check for `docker-compose.yaml`, `Containerfile`, or Kustomize manifests)

## Phase 2: Build Agent Catalog

Read ALL existing `agent.yaml` files to build a comparison catalog:

```bash
find agents -name "agent.yaml" -type f
```

For each `agent.yaml`, extract:

- `name` — the agent's identifier
- `displayName` — human-readable name
- `framework` — the agent framework
- `description` — one-line description
- `deploymentModel` — if present (e.g., `flow-import`)
- RHOAI components — apply the same env var mapping from Phase 1

Also note the directories under `agents/` that have NO `agent.yaml` (deployment-only entries). List them as reference but do not include them in the overlap comparison.

Present the catalog to the user as a table so they can see the full landscape:

| Agent | Framework | Components | Purpose |
|-------|-----------|------------|---------|
| (populated from agent.yaml files) | | | |

## Phase 3: Score Each Dimension

Run 4 checks. Each produces a GREEN, YELLOW, or RED score with reasoning.

### Check 1: Sentence completion

Attempt to fill in:

> "As an AI engineer, I need to know how to build an agent using **[framework]** and integrate it with these RHOAI components: **[components]** for **[purposes]**"

Scoring:

- **GREEN**: sentence completes naturally — framework is named, at least one RHOAI component with a clear purpose, and the purpose is distinct from existing agents
- **YELLOW**: sentence completes but with issues — purpose is vague ("general agent"), only inference component (OGX/vLLM) with no additional RHOAI integration beyond tracing, or framework is "new" with no justification
- **RED**: sentence cannot complete — no RHOAI component integration at all (deployment-only tool), or purpose is empty/undefined

### Check 2: RHOAI component standardness

Classify each component the agent uses:

- **Standard**: OGX/vLLM, MLflow, Milvus, PostgreSQL, MCP servers
- **Non-standard**: Ollama, Langfuse, LiteLLM, or any component not in the standard set

Aggregate scoring:

- **GREEN**: all components are standard
- **YELLOW**: at least one non-standard component is present (needs PM discussion on whether to showcase it), OR the agent uses ONLY OGX/vLLM for inference with no additional RHOAI components beyond the base
- **RED**: no RHOAI components at all

### Check 3: Overlap detection

Compare the proposed agent's (framework, components, purpose) tuple against the catalog from Phase 2. The key question for each comparison: **"Would an AI engineer learn something new from this template that they cannot learn from the existing one?"**

Scoring:

- **GREEN**: unique combination of framework + components, or same framework but clearly distinct purpose and component set (e.g., LangGraph + Milvus is distinct from LangGraph + PostgreSQL)
- **YELLOW**: partial overlap — same framework with similar purpose but different components, OR different framework with identical components and purpose. List the overlapping agents and explain what the new agent adds.
- **RED**: exact duplicate — same framework AND same component set AND indistinguishable purpose (e.g., another LangGraph ReAct agent with only OGX/vLLM + MLflow)

### Check 4: Conformance (existing agent mode only)

In idea mode, skip this check — use the contributor's self-reported answers and note "self-reported" in the output.

In existing agent mode, check:

**API contract:**

- GREEN: has `POST /chat/completions` (JSON + SSE) and `GET /health`
- YELLOW: has endpoints but non-standard (different path, missing SSE), or uses `deploymentModel: flow-import`
- RED: no API endpoints found

**Container pattern:**

- GREEN: UBI9 base, port 8080, UID 1001
- YELLOW: partially conformant (e.g., different base image but correct port/UID)
- RED: no Dockerfile, or fundamentally different pattern

**Required files** (check for existence):

- `agent.yaml` — agent metadata
- `Makefile` — build/deploy interface
- `.env.example` — environment template
- `README.md` — documentation
- `src/` — source code directory
- `tests/` — test directory

List missing files as flags.

## Phase 4: Compute Overall Fit Score

Aggregation rules:

- **GREEN**: all checks are GREEN, or conformance (Check 4) has at most one YELLOW sub-dimension while all other checks are GREEN
- **YELLOW**: at least one YELLOW check but no RED checks
- **RED**: any check is RED

## Phase 5: Generate GitHub Discussion Draft

Produce a complete markdown document formatted for posting as a GitHub Discussion. Present it to the user in a code block so they can copy it.

Use this template:

````markdown
## Agent Proposal: [Display Name or Working Title]

### Fit Score: [GREEN / YELLOW / RED]

### The Sentence

> As an AI engineer, I need to know how to build an agent using **[framework]**
> and integrate it with these RHOAI components: **[component]** for **[purpose]**[, **[component]** for **[purpose]**]...

### Score Breakdown

| Dimension | Score | Details |
|-----------|-------|---------|
| Sentence completion | [GREEN/YELLOW/RED] | [one-line reasoning] |
| RHOAI components | [GREEN/YELLOW/RED] | [list components with standard/non-standard flags] |
| Overlap | [GREEN/YELLOW/RED] | [overlap details or "No overlap with existing agents"] |
| API conformance | [GREEN/YELLOW/RED/N/A] | [details or "Self-reported: [yes/no]" in idea mode] |
| Container conformance | [GREEN/YELLOW/RED/N/A] | [details or "Self-reported: [yes/no]" in idea mode] |

### Proposed Location

```
agents/<framework>/<templates|examples>/<agent_name>/
```

### What This Agent Adds

[Differentiation summary — what new capability does this demonstrate that existing agents do not?]

### Existing Agents for Reference

| Agent | Framework | RHOAI Components | Key Capability |
|-------|-----------|-----------------|----------------|
| [populated from catalog] | | | |

### Flags

[Bulleted list of any YELLOW or RED items with specific recommendations]

### Next Steps

[Conditional on score:]

**GREEN**: This agent fits the repo. Proceed with implementation following [docs/adding-a-new-agent.md](docs/adding-a-new-agent.md). Link this discussion in your PR.

**YELLOW**: This agent may fit but has flagged items that need team discussion. Post this discussion and wait for maintainer/PM feedback before writing code. Address the flagged items in the discussion thread.

**RED**: This agent does not currently fit the repo's scope. [Specific recommendations: e.g., "Consider adding RHOAI component integration", "This overlaps with [existing agent] — consider extending that agent instead", "Deployment-only entries need PM approval — discuss with the team whether building agents on this platform is a supported use case."]

---
*Generated by `/agentic-starter-kits-skills:fit-check`*
````

After presenting the draft, tell the contributor:

1. Create a new GitHub Discussion in the [agentic-starter-kits repo](https://github.com/red-hat-data-services/agentic-starter-kits/discussions) under the **Agent Proposals** category (or **General** if the category does not exist yet).
2. Paste the draft as the discussion body.
3. Tag the repo maintainers for review.
4. Once the discussion is approved, link it in the PR description when submitting code.

The skill does NOT create the discussion automatically — it generates the markdown for the contributor to post.

## Definition of Done

- [ ] Mode determined (idea or existing agent)
- [ ] All 6 dimensions answered (via questionnaire or extraction)
- [ ] Agent catalog built from all existing `agent.yaml` files
- [ ] All checks scored (4 checks in existing mode, 3 in idea mode with Check 4 self-reported)
- [ ] Overall fit score computed
- [ ] GitHub Discussion draft generated and presented to the user
- [ ] For existing agent mode: any conformance issues listed with specific file paths
