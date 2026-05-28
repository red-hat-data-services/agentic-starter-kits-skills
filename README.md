# agentic-starter-kits-skills

Claude Code skills for [agentic-starter-kits](https://github.com/red-hat-data-services/agentic-starter-kits) contributors.

## Skills

| Skill | Description | Usage |
|-------|-------------|-------|
| deploy-agents | Deploy agents to OpenShift with auto-detected cluster config and MLflow token refresh | `/agentic-starter-kits-skills:deploy-agents <agent_paths or 'all'> [--token-only]` |
| add-behavioral-tests | Add behavioral testing (pytest + EvalHub) to an agent | `/agentic-starter-kits-skills:add-behavioral-tests <agent_path> [JIRA-KEY]` |

## Install

Add the marketplace and install the plugin:

```
claude plugin marketplace add red-hat-data-services/agentic-starter-kits-skills
claude plugin install agentic-starter-kits-skills@agentic-starter-kits-skills
```

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

If you previously used these skills from `~/.claude/skills/`, remove the old local directories after installing the plugin to prevent duplicate hook execution:

```bash
rm -rf ~/.claude/skills/deploy-agents
rm -rf ~/.claude/skills/add-behavioral-tests
# Only remove _shared if no other local skills depend on it
```

## License

[MIT](LICENSE)
