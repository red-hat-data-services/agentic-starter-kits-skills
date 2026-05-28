#!/usr/bin/env bash
# Test harness for eval-hook.py — agentic-starter-kits-skills plugin
# Verifies correct behavior for all hook scenarios including assertion execution,
# cross-skill isolation, and cross-plugin isolation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
HOOK_SCRIPT="$SCRIPT_DIR/eval-hook.py"
PASS=0
FAIL=0

if [[ ! -f "$HOOK_SCRIPT" ]]; then
    echo "ERROR: eval-hook.py not found at $HOOK_SCRIPT"
    exit 1
fi

run_test() {
    local name="$1"
    local input="$2"
    local expect="$3"  # "output" or "silent"
    local check="$4"   # substring to look for in output (if expect=output)

    local output
    output=$(echo "$input" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" EVAL_HOOK_DEBUG="" python3 "$HOOK_SCRIPT" 2>/dev/null) || true

    if [[ "$expect" == "silent" ]]; then
        if [[ -z "$output" ]]; then
            echo "  PASS: $name"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $name — expected silent exit, got output: $output"
            FAIL=$((FAIL + 1))
        fi
    elif [[ "$expect" == "output" ]]; then
        if [[ -z "$output" ]]; then
            echo "  FAIL: $name — expected output, got silence"
            FAIL=$((FAIL + 1))
        elif [[ "$output" == *"$check"* ]]; then
            echo "  PASS: $name"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $name — output missing '$check': $output"
            FAIL=$((FAIL + 1))
        fi
    fi
}

run_test_absent() {
    local name="$1"
    local input="$2"
    local absent="$3"  # substring that must NOT appear

    local output
    output=$(echo "$input" | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" EVAL_HOOK_DEBUG="" python3 "$HOOK_SCRIPT" 2>/dev/null) || true

    if [[ -z "$output" ]]; then
        echo "  FAIL: $name — no output at all"
        FAIL=$((FAIL + 1))
    elif [[ "$output" != *"$absent"* ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name — output contains '$absent'"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== eval-hook.py test harness (agentic-starter-kits-skills plugin) ==="
echo "Plugin root: $PLUGIN_ROOT"
echo ""

# ===================================================================
# deploy-agents skill tests
# ===================================================================

echo "--- deploy-agents: PreToolUse ---"

run_test \
    "emits eval-gate XML for deploy-agents skill" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "eval-gate"

run_test \
    "includes permissionDecision" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "permissionDecision"

run_test \
    "runs exec assertions (shows PASS or FAIL)" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "Executable assertion results"

run_test \
    "includes assertion IDs (repo-root, oc-auth, helm-installed)" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "repo-root"

run_test \
    "includes oc-auth assertion" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "oc-auth"

run_test \
    "includes helm-installed assertion" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "helm-installed"

run_test \
    "includes eval assertions for Claude (args-provided)" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "args-provided"

run_test \
    "status line shows assertion counts" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "assertions"

echo ""
echo "--- deploy-agents: PostToolUse ---"

run_test \
    "emits eval-gate XML" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "eval-gate"

run_test \
    "includes post-conditions text" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "post-conditions to confirm success"

run_test_absent \
    "PostToolUse does NOT include permissionDecision" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "permissionDecision"

run_test \
    "post gate has exec assertions (no-env-committed)" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "no-env-committed"

run_test \
    "post gate has exec assertions (no-chart-modifications)" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "no-chart-modifications"

run_test \
    "post gate has eval assertions (summary-generated)" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "summary-generated"

run_test \
    "post gate has eval assertions (tracing-verified)" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "tracing-verified"

echo ""
echo "--- deploy-agents: Edge cases ---"

run_test \
    "--token-only arg still triggers gates" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"--token-only"}}' \
    "output" \
    "eval-gate"

run_test \
    "all arg still triggers gates" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"all"}}' \
    "output" \
    "eval-gate"

run_test \
    "no args still emits eval assertions" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":""}}' \
    "output" \
    "eval-gate"

run_test \
    "multiple agent paths still triggers gates" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent langgraph/react_agent"}}' \
    "output" \
    "eval-gate"

run_test \
    "deploy-agents status line shows correct skill name" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "output" \
    "agentic-starter-kits-skills:deploy-agents"

# ===================================================================
# add-behavioral-tests skill tests
# ===================================================================

echo ""
echo "--- add-behavioral-tests: PreToolUse ---"

run_test \
    "emits eval-gate XML" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag RHAIENG-4223"}}' \
    "output" \
    "eval-gate"

run_test \
    "includes permissionDecision" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "permissionDecision"

run_test \
    "includes pre-conditions text" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "pre-conditions before proceeding"

run_test \
    "runs exec assertions (shows PASS or FAIL)" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "Executable assertion results"

run_test \
    "includes assertion IDs" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "repo-root"

run_test \
    "includes eval assertions for Claude" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "Pass if:"

run_test \
    "resolves agent path in exec commands" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "agent-dir-exists"

run_test \
    "status line shows assertion counts" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "assertions"

echo ""
echo "--- add-behavioral-tests: PostToolUse ---"

run_test \
    "emits eval-gate XML" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "eval-gate"

run_test \
    "includes post-conditions text" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "post-conditions to confirm success"

run_test_absent \
    "PostToolUse does NOT include permissionDecision" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "permissionDecision"

run_test \
    "post gate has exec assertions (dod-satisfied)" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "dod-satisfied"

run_test \
    "post gate has eval assertions (11a-passed)" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "11a-passed"

run_test \
    "PostToolUse includes report template" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "eval-report"

run_test \
    "report template has agent name" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "agentic_rag"

run_test \
    "report template has summary table" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "| Gate | Result |"

run_test \
    "report template has all gates" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "phase-11e"

run_test \
    "report template has MLflow section" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "MLflow Trace Summary"

run_test \
    "report template has EvalHub section" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "EvalHub E2E Summary"

run_test \
    "report template has output path" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "tests/behavioral/reports/BTEST_VALIDATION_REPORT_agentic_rag.md"

run_test_absent \
    "PreToolUse does NOT include report template" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "eval-report"

echo ""
echo "--- add-behavioral-tests: Edge cases ---"

run_test \
    "No args still emits eval assertions" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":""}}' \
    "output" \
    "eval-gate"

run_test \
    "Args without slash — agent path empty, exec assertions still run" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"RHAIENG-4223"}}' \
    "output" \
    "eval-gate"

# ===================================================================
# Cross-skill isolation
# ===================================================================

echo ""
echo "--- Cross-skill isolation ---"

run_test_absent \
    "deploy-agents PreToolUse does NOT emit add-behavioral-tests content" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "agent-dir-exists"

run_test_absent \
    "add-behavioral-tests PreToolUse does NOT emit deploy-agents content" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "helm-installed"

run_test_absent \
    "deploy-agents PostToolUse does NOT include eval-report template" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:deploy-agents","args":"crewai/websearch_agent"}}' \
    "eval-report"

run_test \
    "add-behavioral-tests PostToolUse DOES include eval-report template" \
    '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests","args":"langgraph/agentic_rag"}}' \
    "output" \
    "eval-report"

# ===================================================================
# Cross-plugin isolation
# ===================================================================

echo ""
echo "--- Cross-plugin isolation ---"

run_test \
    "rosa-rhoai skill is silent (foreign plugin)" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"rosa-rhoai:gpu-add","args":""}}' \
    "silent" \
    ""

run_test \
    "bare skill name (no plugin prefix) is silent" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"deploy-agents","args":"all"}}' \
    "silent" \
    ""

run_test \
    "unknown plugin skill is silent" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"some-other-plugin:some-skill","args":""}}' \
    "silent" \
    ""

# ===================================================================
# Non-matching scenarios
# ===================================================================

echo ""
echo "--- Non-matching scenarios (expect silent) ---"

run_test \
    "Non-Skill tool (Bash) is silent" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
    "silent" \
    ""

run_test \
    "Non-Skill tool (Read) is silent" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/test"}}' \
    "silent" \
    ""

run_test \
    "Unknown hook event is silent" \
    '{"hook_event_name":"UserPromptSubmit","tool_name":"Skill","tool_input":{"skill":"agentic-starter-kits-skills:add-behavioral-tests"}}' \
    "silent" \
    ""

run_test \
    "Empty input is silent" \
    '' \
    "silent" \
    ""

run_test \
    "No skill name is silent" \
    '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{}}' \
    "silent" \
    ""

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
