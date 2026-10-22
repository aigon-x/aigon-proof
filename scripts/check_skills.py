#!/usr/bin/env python3
"""Validate the shipped skill bundle.

Fails (exit 1) when the bundle is not self-consistent:
  - a SKILL.md has no or invalid YAML frontmatter, name/description,
  - the frontmatter name does not match the directory name,
  - two skills share a name,
  - a relative markdown link points at a file that is not shipped,
  - an explicit cross-reference (`Skill: <name>`) points at a skill that is not
    shipped. Internal-only names are acknowledged with "(outside this bundle)".

Cross-references use one convention: `Skill: <name>` or `skill: <name>`.
Model names, file names and prose mentions are deliberately not treated as
references, so the gate does not produce false positives.

Standard library only, so CI needs no extra dependency.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SKILLS = ROOT / "skills"
CATEGORIES = {"agents", "engineering", "governance", "mcp", "security"}
REFERENCE = re.compile(r"(?:^|[\s(`])[Ss]kill:\s*`?([a-z0-9][a-z0-9-]+)`?")
ACK = ("outside this bundle", "spoza tego bundla")


def parse_frontmatter(text):
    """Parse the simple frontmatter we use, including block scalars (`>` and `|`)."""
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end == -1:
        return None
    fields, key, buf = {}, None, []
    for raw in text[3:end].splitlines():
        if raw.startswith((" ", "\t")) and key is not None:
            buf.append(raw.strip())
            continue
        if key is not None:
            fields[key] = " ".join(buf).strip() or fields.get(key, "")
            key, buf = None, []
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", raw)
        if not m:
            continue
        name, value = m.group(1), m.group(2).strip()
        if value in (">", "|", ">-", "|-", ">+", "|+"):
            key = name
        else:
            fields[name] = value.strip("\"'")
    if key is not None:
        fields[key] = " ".join(buf).strip()
    return fields


def main():
    errors = []
    files = sorted(SKILLS.glob("*/*/SKILL.md"))
    if not files:
        print("FAIL: no skills/*/*/SKILL.md found")
        return 1

    names = {}
    for path in files:
        rel = path.relative_to(ROOT)
        text = path.read_text(encoding="utf-8", errors="ignore")
        fm = parse_frontmatter(text)
        if fm is None:
            errors.append(f"{rel}: missing or unterminated YAML frontmatter")
            continue
        name, desc = fm.get("name", ""), fm.get("description", "")
        if not name:
            errors.append(f"{rel}: missing name")
        elif name != path.parent.name:
            errors.append(f"{rel}: name '{name}' != directory '{path.parent.name}'")
        if not desc:
            errors.append(f"{rel}: missing description")
        elif len(desc) < 20:
            errors.append(f"{rel}: description too short ({len(desc)} chars)")
        if name:
            names.setdefault(name, []).append(str(rel))
        if path.parent.parent.name not in CATEGORIES:
            errors.append(f"{rel}: unknown category '{path.parent.parent.name}'")

        body = text[text.find("\n---", 3) + 4:]
        for link in re.findall(r"\]\(([^)\s]+)\)", body):
            if link.startswith(("http://", "https://", "mailto:", "#")):
                continue
            if not (path.parent / link.split("#")[0]).resolve().exists():
                errors.append(f"{rel}: dead relative link -> {link}")

    for name, where in names.items():
        if len(where) > 1:
            errors.append(f"duplicate skill name '{name}': {', '.join(where)}")

    shipped = set(names)
    for path in files:
        rel = path.relative_to(ROOT)
        for lineno, line in enumerate(
            path.read_text(encoding="utf-8", errors="ignore").splitlines(), 1
        ):
            if any(a in line for a in ACK):
                continue
            for ref in REFERENCE.findall(line):
                if ref not in shipped:
                    errors.append(
                        f"{rel}:{lineno}: reference to unshipped skill '{ref}' "
                        f"(use a shipped skill, or mark it outside this bundle)"
                    )

    if errors:
        print(f"FAIL: {len(errors)} problem(s) in {len(files)} skills")
        for e in errors:
            print("  -", e)
        return 1

    print(f"OK: {len(files)} skills, {len(names)} unique names, "
          f"{len(CATEGORIES)} categories, no dead links or dangling references")
    return 0


if __name__ == "__main__":
    sys.exit(main())
