---
name: canon-law-check
description: Verify that AIOS canonical includes all laws defined in PROD.
version: 0.1.0
category: quality-assurance

---


# Canon Law Verification Skill
## Overview
This skill automates the cross‑reference of the *product* law set defined in
`<workspace>/config/canonical/constitution.generated.yaml` against the laws
currently available in the AIOS canonical tree. It reports missing laws,
mismatched bindings, and optionally copies the authoritative set into the
AIOS repo so future audits can be performed locally.

## Dependencies
- `diff` for comparing YAML blocks.
- `sed`/`awk` for extracting `id:` lines.
- `cp`/`rsync` for copying the authority file.

## Use‑case
1. Run `canon-law-check` at the start of a project release cycle.
2. Inspect the console report—it lists each law id, its status (PASS / MISSING),
and the associated file/line.
3. If any laws are marked **MISSING**, invoke the optional helper script
   `scripts/copy-laws.sh` to propagate the full law definition into AIOS.

## Pitfalls
- The script assumes both sources are YAML files; any differences in formatting
  (e.g. trailing spaces) can spuriously flag missing laws.
- If the AIOS repo is not under `/opt/AIos` please update the `-i`/`-o`
  arguments accordingly.

## Strategy
The skill contains a short Bash wrapper that:
- Extracts all law ids from the PROD file.
- Extracts all law ids from the AIOS `laws.yaml` (if present).
- Prints a comparative table.
- Exports the authoritative file to `scripts/authoritative-laws.yaml` for
  future referential purposes.

---

## References
See `scripts/copy-laws.sh` for the concrete copy operation.
