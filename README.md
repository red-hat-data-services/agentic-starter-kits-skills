# agentic-starter-kits-skills

Claude Code skills for [agentic-starter-kits](https://github.com/red-hat-data-services/agentic-starter-kits) contributors.

## Skills

| Skill | Description | Usage |
|-------|-------------|-------|
| fit-check | Validate whether a new agent belongs in the repo (idea mode or existing code) | `/agentic-starter-kits-skills:fit-check [agent_path]` |
| deploy-agents | Deploy agents to OpenShift with auto-detected cluster config and MLflow token refresh | `/agentic-starter-kits-skills:deploy-agents <agent_paths or 'all'> [--token-only]` |
| add-behavioral-tests | Scaffold behavioral testing (pytest) for an agent | `/agentic-starter-kits-skills:add-behavioral-tests <agent_path> [JIRA-KEY]` |
| run-behavioral-tests | Run and validate behavioral tests for an agent | `/agentic-starter-kits-skills:run-behavioral-tests <agent_path>` |
| add-integration-tests | Add integration tests for agent deployment verification | `/agentic-starter-kits-skills:add-integration-tests <agent_path> [JIRA-KEY]` |
| integrate-tracing | Orchestrate end-to-end MLflow tracing integration into an agent template | `/agentic-starter-kits-skills:integrate-tracing <framework> <agent_path>` |
| check-autolog-support | Research and classify a framework's MLflow autolog support level (A, B, or C) | `/agentic-starter-kits-skills:check-autolog-support <framework>` |
| create-tracing-module | Create the tracing.py module with enable_tracing() and framework-specific autolog | `/agentic-starter-kits-skills:create-tracing-module <agent_path> [framework]` |
| wire-into-lifespan | Wire enable_tracing() into the FastAPI lifespan and add imports to main.py | `/agentic-starter-kits-skills:wire-into-lifespan <agent_path>` |
| add-manual-tracing | Add manual MLflow trace wrapping for tool and agent spans (Level B/C agents) | `/agentic-starter-kits-skills:add-manual-tracing <agent_path>` |
| verify-traces | Verify tracing works correctly via code review and live trace testing | `/agentic-starter-kits-skills:verify-traces <agent_path>` |
| review-tracing-code | Review tracing integration code for correctness against repo patterns | `/agentic-starter-kits-skills:review-tracing-code <agent_path>` |
| test-tracing | Test MLflow tracing end-to-end by starting servers, sending requests, and verifying spans | `/agentic-starter-kits-skills:test-tracing <agent_path>` |
| kagenti-deploy | Deploy A2A-compliant agents to OpenShift/Kubernetes with kagenti integration | `/agentic-starter-kits-skills:kagenti-deploy` |

## Install in Claude Code

Add the marketplace and install the plugin:

```
claude plugin marketplace add red-hat-data-services/agentic-starter-kits-skills
claude plugin install agentic-starter-kits-skills@agentic-starter-kits-skills
```

This repository is a self-hosted Claude Code marketplace. Public community-catalog
submission and review are handled through Anthropic's plugin submission process.

## Install in OpenCode

OpenCode consumes remote skill catalogs rather than Claude marketplaces. Add this
to your OpenCode configuration:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "skills": {
    "urls": [
      "https://raw.githubusercontent.com/red-hat-data-services/agentic-starter-kits-skills/main/skills/"
    ]
  }
}
```

Restart OpenCode after changing the configuration. Skills are available by their
unscoped names, such as `fit-check` and `deploy-agents`. The catalog is defined
by `skills/index.json`; increment a skill version when its files change so
OpenCode refreshes its cache.

For local contributor development, use `skills.paths` with an absolute path to
the repository's `skills` directory instead.

OpenCode does not support Claude's namespaced slash commands, Claude lifecycle
hooks, or equivalent handling for `$ARGUMENTS`, `disable-model-invocation`, and
`argument-hint`. Claude `PreToolUse`/`PostToolUse` evaluation gates are therefore
not enforced by OpenCode; use normal OpenCode permissions for deployments and
other destructive operations.

## Contributing

To add a new skill:

1. Create a new directory under `skills/` (e.g., `skills/my-new-skill/`)
2. Add a `SKILL.md` file with YAML frontmatter (`name`, `description`) and markdown content
3. Optionally add `skills/<skill-name>/references/eval-criteria-<name>.json` for gate evaluation -- use `agentic-starter-kits-skills:<skill-name>` as the top-level key
4. Update `.claude-plugin/marketplace.json` to include the new skill's name and description if it belongs in a separate plugin entry

`plugin.json` (in `.claude-plugin/`) is the plugin manifest -- it tells Claude Code where to find skills. It does not need updating when adding a skill, since it points to the `skills/` directory and auto-discovers `SKILL.md` files.

## Testing

Run the eval-hook test suite:

```bash
./scripts/test-eval-hook.sh
```

## Migration from Local Skills

If you previously used these skills from `.claude/skills/` in the agentic-starter-kits repo or from `~/.claude/skills/`, remove the old local directories after installing the plugin to prevent duplicates:

```bash
# From agentic-starter-kits repo root (if skills were checked in)
rm -rf .claude/skills/integrate-tracing
rm -rf .claude/skills/check-autolog-support
rm -rf .claude/skills/create-tracing-module
rm -rf .claude/skills/wire-into-lifespan
rm -rf .claude/skills/add-manual-tracing
rm -rf .claude/skills/verify-traces
rm -rf .claude/skills/review-tracing-code
rm -rf .claude/skills/test-tracing
rm -rf .claude/skills/kagenti-deploy

# From user-level skills (if any were installed locally)
rm -rf ~/.claude/skills/deploy-agents
rm -rf ~/.claude/skills/add-behavioral-tests
rm -rf ~/.claude/skills/run-behavioral-tests
rm -rf ~/.claude/skills/integrate-tracing
rm -rf ~/.claude/skills/check-autolog-support
rm -rf ~/.claude/skills/create-tracing-module
rm -rf ~/.claude/skills/wire-into-lifespan
rm -rf ~/.claude/skills/add-manual-tracing
rm -rf ~/.claude/skills/verify-traces
rm -rf ~/.claude/skills/review-tracing-code
rm -rf ~/.claude/skills/test-tracing
rm -rf ~/.claude/skills/kagenti-deploy
```

## License

[MIT](LICENSE)
