#!/usr/bin/env python3
"""
Evaluate skill outcome gates for any skill with eval-criteria.

Executed by PreToolUse and PostToolUse hooks when the Skill tool is invoked.
Scans ${CLAUDE_PLUGIN_ROOT}/skills/*/references/eval-criteria-*.json files,
runs executable assertions, and injects gate evaluation results as additionalContext.

For PreToolUse: runs exec assertions, injects pre-condition results + eval criteria
For PostToolUse: runs exec assertions, injects post-condition results + eval criteria

Assertion types:
  exec  — shell command run by this script; reports PASS/FAIL with exit code
  eval  — structured criteria for Claude to evaluate against tool output
"""

import glob
import json
import os
import subprocess
import sys
from typing import Any, Dict, List, Optional

if not os.environ.get("EVAL_HOOK_DEBUG"):
    sys.stderr = open(os.devnull, "w")

EXEC_TIMEOUT = 3


def read_hook_input() -> Dict[str, Any]:
    try:
        hook_input = sys.stdin.read()
        return json.loads(hook_input) if hook_input.strip() else {}
    except json.JSONDecodeError as e:
        print(f"ERROR: Failed to parse hook input JSON: {e}", file=sys.stderr)
        return {}


PLUGIN_NAME = "agentic-starter-kits-skills"


def get_plugin_root() -> str:
    """Get the plugin root directory from CLAUDE_PLUGIN_ROOT or script location."""
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    if plugin_root:
        return plugin_root
    script_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(script_dir)


def get_all_references_dirs() -> list[str]:
    """Find all skill references directories within the plugin."""
    plugin_root = get_plugin_root()
    skills_root = os.path.join(plugin_root, "skills")
    dirs = []
    if os.path.isdir(skills_root):
        for skill_dir in sorted(os.listdir(skills_root)):
            ref_dir = os.path.join(skills_root, skill_dir, "references")
            if os.path.isdir(ref_dir):
                dirs.append(ref_dir)
    return dirs


def load_eval_criteria() -> Dict[str, Any]:
    references_dirs = get_all_references_dirs()

    if not references_dirs:
        debug("No skill references directories found")
        return {}

    merged = {}
    for references_dir in references_dirs:
        pattern = os.path.join(references_dir, "eval-criteria-*.json")
        files = glob.glob(pattern)

        for filepath in sorted(files):
            debug(f"Loading criteria from {filepath}")
            try:
                with open(filepath, "r") as f:
                    data = json.load(f)
                    merged.update(data)
            except json.JSONDecodeError as e:
                debug(f"Failed to parse {filepath}: {e}")
    return merged


def extract_skill_name(hook_input: Dict[str, Any]) -> Optional[str]:
    tool_input = hook_input.get("tool_input", {})
    if isinstance(tool_input, dict):
        return tool_input.get("skill", "")
    return ""


def extract_agent_path(hook_input: Dict[str, Any]) -> str:
    tool_input = hook_input.get("tool_input", {})
    if not isinstance(tool_input, dict):
        return ""
    args = tool_input.get("args", "")
    if not args:
        return ""
    first_arg = args.strip().split()[0]
    return first_arg if "/" in first_arg else ""


def resolve_variables(command: str, agent_path: str) -> str:
    if not agent_path:
        return command

    parts = agent_path.split("/")
    agent_name = parts[-1] if parts else ""
    agent_key = agent_name.replace("-", "_").replace(" ", "_")
    agent_short = agent_name
    agent_route_var = agent_key.upper() + "_ROUTE"

    command = command.replace("${AGENT_PATH}", agent_path)
    command = command.replace("${AGENT_KEY}", agent_key)
    command = command.replace("${AGENT_SHORT}", agent_short)
    command = command.replace("${AGENT_ROUTE_VAR}", agent_route_var)
    return command


def run_exec_assertion(assertion: Dict[str, Any], agent_path: str) -> Dict[str, Any]:
    command = resolve_variables(assertion["command"], agent_path)
    assertion_id = assertion["id"]
    description = assertion["description"]
    on_fail = assertion.get("on_fail", "warn")

    debug(f"Running exec assertion '{assertion_id}': {command}")

    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=EXEC_TIMEOUT,
        )
        passed = result.returncode == 0
        output = result.stdout.strip() or result.stderr.strip()
    except subprocess.TimeoutExpired:
        passed = False
        output = f"Timed out after {EXEC_TIMEOUT}s"
    except Exception as e:
        passed = False
        output = str(e)

    status = "PASS" if passed else "FAIL"
    debug(f"  {status}: {assertion_id} — {description}")

    return {
        "id": assertion_id,
        "status": status,
        "description": description,
        "on_fail": on_fail,
        "output": output,
    }


def run_assertions(
    assertions: List[Dict[str, Any]], agent_path: str
) -> tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    exec_results = []
    eval_assertions = []

    for assertion in assertions:
        if assertion["type"] == "exec":
            exec_results.append(run_exec_assertion(assertion, agent_path))
        elif assertion["type"] == "eval":
            eval_assertions.append(assertion)

    return exec_results, eval_assertions


def format_assertion_context(
    phase: str,
    command: str,
    description: str,
    exec_results: List[Dict[str, Any]],
    eval_assertions: List[Dict[str, Any]],
) -> str:
    lines = []

    if exec_results:
        lines.append("Executable assertion results:")
        for r in exec_results:
            marker = "PASS" if r["status"] == "PASS" else "FAIL"
            line = f"  [{marker}] {r['id']}: {r['description']}"
            if r["status"] == "FAIL" and r["output"]:
                line += f" — {r['output']}"
            lines.append(line)
        lines.append("")

    if eval_assertions:
        if phase == "pre":
            lines.append("Evaluate these pre-conditions before proceeding:")
        else:
            lines.append("Evaluate these post-conditions to confirm success:")

        for a in eval_assertions:
            lines.append(f"  [{a['id']}] {a['description']}")
            if "pass_if" in a:
                lines.append(f"    Pass if: {a['pass_if']}")
        lines.append("")

    body = "\n".join(lines)
    return f'<eval-gate phase="{phase}" command="{command}" description="{description}">\n{body}</eval-gate>'


def format_status_line(
    phase: str,
    command: str,
    exec_results: List[Dict[str, Any]],
    eval_assertions: List[Dict[str, Any]],
) -> str:
    phase_label = "Pre-check" if phase == "pre" else "Post-check"
    total = len(exec_results) + len(eval_assertions)
    passed = sum(1 for r in exec_results if r["status"] == "PASS")
    failed = sum(1 for r in exec_results if r["status"] == "FAIL")
    pending = len(eval_assertions)

    parts = [f"{total} assertions"]
    if exec_results:
        parts.append(f"{passed} passed")
    if failed:
        parts.append(f"{failed} FAILED")
    if pending:
        parts.append(f"{pending} for Claude to evaluate")

    return f"[eval-gate] {phase_label}: {command} — {', '.join(parts)}"


def detect_cluster_info() -> Dict[str, str]:
    info = {"cluster": "<unknown>", "namespace": "<unknown>", "server": "<unknown>"}
    try:
        r = subprocess.run(
            "oc whoami --show-server",
            shell=True, capture_output=True, text=True, timeout=1,
        )
        if r.returncode == 0:
            server = r.stdout.strip()
            info["server"] = server
            # Extract cluster name from API URL: https://api.<cluster>.<hash>.p3.openshiftapps.com:443
            parts = server.replace("https://", "").replace("http://", "").split(".")
            if len(parts) >= 2 and parts[0] == "api":
                info["cluster"] = parts[1]
    except Exception:
        pass
    try:
        r = subprocess.run(
            "oc project -q",
            shell=True, capture_output=True, text=True, timeout=1,
        )
        if r.returncode == 0:
            info["namespace"] = r.stdout.strip()
    except Exception:
        pass
    return info


def build_report_template(command_criteria: Dict[str, Any], agent_path: str, skill_name: str) -> str:
    parts = agent_path.split("/") if agent_path else []
    agent_name = parts[-1] if parts else "<agent_name>"

    skill_short = skill_name.split(":")[-1]
    report_config = command_criteria.get("report", {})
    report_path = report_config.get("path", "reports/VALIDATION_REPORT_{agent_name}.md").format(agent_name=agent_name)
    sections = report_config.get("sections", [])

    cluster = detect_cluster_info()

    lines = [
        f'<eval-report command="{skill_short}">',
        "Generate a Validation report. Fill in every [ ] with PASS, FAIL, WAIVED, or SKIPPED based on what happened during this session.",
        f"Write the completed report to: {report_path}",
        "",
        "---",
        "",
        f"# Validation Report: {agent_name}",
        "",
        f"**Agent**: `agents/{agent_path}/`",
        "**Date**: <fill in>",
        f"**Cluster**: {cluster['cluster']} (ROSA HCP)",
        f"**Namespace**: {cluster['namespace']}",
        "**Route**: <fill in agent route URL>",
        "**MLflow Experiment**: <fill in>",
        "",
        "## Summary",
        "",
        "| Gate | Result | Assertions | Notes |",
        "| ---- | ------ | ---------- | ----- |",
    ]

    all_gates = []

    pre = command_criteria.get("pre")
    if pre:
        count = len(pre.get("assertions", []))
        all_gates.append(("pre", pre))
        lines.append(f"| pre | [ ] | {count} | Skill invocation |")

    gates = command_criteria.get("gates", {})
    for gate_id, gate in gates.items():
        count = len(gate.get("assertions", []))
        hard = " **HARD GATE**" if gate.get("hard_gate") else ""
        all_gates.append((gate_id, gate))
        lines.append(f"| {gate_id} | [ ] | {count} | {gate.get('description', '')}{hard} |")

    post = command_criteria.get("post")
    if post:
        count = len(post.get("assertions", []))
        all_gates.append(("post", post))
        lines.append(f"| post | [ ] | {count} | Completion verification |")

    lines.append("")
    lines.append("## Detailed Results")

    for gate_id, gate in all_gates:
        desc = gate.get("description", "")
        lines.append("")
        lines.append(f"### {gate_id}: {desc}")
        lines.append("")

        assertions = gate.get("assertions", [])
        for a in assertions:
            a_type = a.get("type", "eval")
            tag = "exec" if a_type == "exec" else "eval"
            lines.append(f"- [ ] `{a['id']}` ({tag}): {a['description']}")

        waiver = gate.get("waiver")
        if waiver:
            lines.append("")
            lines.append(f"**Waiver condition**: {waiver['condition']}")
            lines.append(f"**Waiver action**: {waiver['action']}")

    lines.append("")
    lines.append("## Bugs Filed")
    lines.append("")
    lines.append("| Jira Key | Summary | Phase |")
    lines.append("| -------- | ------- | ----- |")
    lines.append("| <fill in or remove if none> | | |")

    if "mlflow" in sections:
        lines.append("")
        lines.append("## MLflow Trace Summary")
        lines.append("")
        lines.append("- **Experiment**: <fill in>")
        lines.append("- **Total traces**: <fill in>")
        lines.append("- **TOOL spans found**: <yes/no>")
        lines.append("- **CHAT_MODEL spans found**: <yes/no>")
        lines.append("- **Framework spans found**: <yes/no>")
        lines.append("- **Enrichment mode**: <MLflow traces / content heuristics (degraded)>")

    if "evalhub" in sections:
        lines.append("")
        lines.append("## EvalHub E2E Summary")
        lines.append("")
        lines.append("- **Job state**: <completed/failed>")
        lines.append("- **Scores**: <fill in>")
        lines.append("- **Adapter image**: <fill in>")
        lines.append("- **Fixture path**: <fill in>")

    lines.append("")
    lines.append("---")
    lines.append("</eval-report>")

    return "\n".join(lines)


def debug(msg: str) -> None:
    if os.environ.get("EVAL_HOOK_DEBUG"):
        print(f"[eval-hook] {msg}", file=sys.stderr)


def emit_output(hook_event: str, additional_context: str = "", reason: str = "") -> None:
    if not additional_context:
        sys.exit(0)

    hook_output: Dict[str, Any] = {
        "hookEventName": hook_event,
        "additionalContext": additional_context,
    }

    if hook_event == "PreToolUse":
        hook_output["permissionDecision"] = "allow"
        if reason:
            hook_output["permissionDecisionReason"] = reason

    sys.stdout.write(json.dumps({"hookSpecificOutput": hook_output}) + "\n")
    sys.stdout.flush()
    sys.exit(0)


def main():
    hook_input = read_hook_input()

    debug(f"Hook input keys: {list(hook_input.keys())}")

    hook_event = hook_input.get("hook_event_name", "")
    debug(f"hook_event_name={hook_event!r}")
    if hook_event not in ("PreToolUse", "PostToolUse"):
        debug("Skipping: not a PreToolUse/PostToolUse event")
        sys.exit(0)

    tool_name = hook_input.get("tool_name", "")
    debug(f"tool_name={tool_name!r}")
    if tool_name != "Skill":
        debug("Skipping: not a Skill tool invocation")
        sys.exit(0)

    skill_name = extract_skill_name(hook_input)
    debug(f"skill_name={skill_name!r}")
    if not skill_name:
        debug("Skipping: no skill name found in tool_input")
        sys.exit(0)

    if not skill_name.startswith(f"{PLUGIN_NAME}:"):
        debug(f"Skipping: skill {skill_name!r} is not from {PLUGIN_NAME}")
        sys.exit(0)

    criteria = load_eval_criteria()
    debug(f"Loaded criteria for commands: {list(criteria.keys())}")

    if skill_name not in criteria:
        debug(f"Skipping: no criteria defined for skill {skill_name!r}")
        sys.exit(0)

    phase = "pre" if hook_event == "PreToolUse" else "post"

    command_criteria = criteria[skill_name]

    phase_criteria = command_criteria.get(phase)
    if not phase_criteria:
        phase_label = "Pre-check" if phase == "pre" else "Post-check"
        msg = f"[eval-gate] {phase_label}: {skill_name} — no {phase} criteria defined"
        debug(msg)
        emit_output(hook_event, additional_context=msg)
        return

    agent_path = extract_agent_path(hook_input)
    debug(f"agent_path={agent_path!r}")

    assertions = phase_criteria.get("assertions", [])
    if not assertions:
        debug(f"No assertions defined for {phase} gate")
        emit_output(hook_event)
        return

    exec_results, eval_assertions = run_assertions(assertions, agent_path)

    description = phase_criteria.get("description", "")
    context = format_assertion_context(
        phase, skill_name, description, exec_results, eval_assertions
    )
    status = format_status_line(phase, skill_name, exec_results, eval_assertions)
    debug(status)

    full_context = f"{status}\n{context}"

    if phase == "post" and "report" in command_criteria:
        report = build_report_template(command_criteria, agent_path, skill_name)
        full_context = f"{full_context}\n\n{report}"

    emit_output(hook_event, additional_context=full_context, reason=status)


if __name__ == "__main__":
    main()
