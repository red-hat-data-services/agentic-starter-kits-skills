# agentic-starter-kits-skills

Claude Code skills for [agentic-starter-kits](https://github.com/red-hat-data-services/agentic-starter-kits) contributors.

## Install

```
claude install-plugin github:red-hat-data-services/agentic-starter-kits-skills
```

## Skills

| Skill | Description |
|-------|-------------|
| `add-integration-tests` | Skill for adding integration tests to an agentic-starter-kits agent. |
| `add-behavioral-tests` | Skill for adding behavioral tests to an agentic-starter-kits agent. |

## Contributing

To add a new skill:

1. Create a new directory under `skills/` (e.g., `skills/my-new-skill/`)
2. Add a `SKILL.md` file with YAML frontmatter (`name`, `description`) and markdown content
3. Update `marketplace.json` to include the new skill's name and description

`plugin.json` (in `.claude-plugin/`) is the plugin manifest — it tells Claude Code where to find skills. It does not need updating when adding a skill, since it points to the `skills/` directory and auto-discovers `SKILL.md` files.

## License

[MIT](LICENSE)
