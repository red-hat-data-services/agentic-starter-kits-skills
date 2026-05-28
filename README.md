# agentic-starter-kits-skills

Reusable Claude Code skills for building, deploying, and maintaining LLM agent templates on OpenShift.

## Skills

| Skill | Description | Usage |
|-------|-------------|-------|
| deploy-agents | Deploy agents to OpenShift with auto-detected cluster config and MLflow token refresh | `/agentic-starter-kits-skills:deploy-agents <agent_paths or 'all'> [--token-only]` |
| add-behavioral-tests | Add behavioral testing (pytest + EvalHub) to an agent | `/agentic-starter-kits-skills:add-behavioral-tests <agent_path> [JIRA-KEY]` |

## Installation

Install as a Claude Code plugin:

```bash
claude plugin add red-hat-data-services/agentic-starter-kits-skills
```

Or for local development:

```bash
git clone git@github.com:red-hat-data-services/agentic-starter-kits-skills.git
claude plugin add ./agentic-starter-kits-skills
```

## Adding a New Skill

1. Create `skills/<skill-name>/SKILL.md` with frontmatter (`name`, `description`, `argument-hint`)
2. Optionally add `skills/<skill-name>/references/eval-criteria-<name>.json` for gate evaluation
   - Use `agentic-starter-kits-skills:<skill-name>` as the top-level key
3. No changes needed to `hooks/hooks.json` or `scripts/eval-hook.py` -- they auto-discover new skills

## Testing

Run the eval-hook test suite:

```bash
./scripts/test-eval-hook.sh
```

## Migration from Local Skills

If you previously used these skills from `~/.claude/skills/`, remove the old local directories after installing the plugin to prevent duplicate hook execution:

```bash
rm -rf ~/.claude/skills/deploy-agents
rm -rf ~/.claude/skills/add-behavioral-tests
# Only remove _shared if no other local skills depend on it
```
