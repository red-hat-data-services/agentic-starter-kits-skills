#!/usr/bin/env python3
"""Validate the OpenCode remote skills catalog."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).parents[1]
skills_root = ROOT / "skills"
catalog = json.loads((skills_root / "index.json").read_text())
entries = catalog["skills"]
directories = sorted(p.name for p in skills_root.iterdir() if (p / "SKILL.md").is_file())
assert sorted(e["name"] for e in entries) == directories

for entry in entries:
    name = entry["name"]
    assert re.fullmatch(r"\d+\.\d+\.\d+", entry["version"])
    assert "SKILL.md" in entry["files"]
    skill_dir = skills_root / name
    frontmatter = (skill_dir / "SKILL.md").read_text().split("---", 2)[1]
    assert re.search(r"^name:\s*" + re.escape(name) + r"\s*$", frontmatter, re.MULTILINE)
    for file_name in entry["files"]:
        path = Path(file_name)
        assert not path.is_absolute() and ".." not in path.parts
        assert (skill_dir / path).is_file(), (name, file_name)

print(f"validated {len(entries)} OpenCode skills")
