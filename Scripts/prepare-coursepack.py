#!/usr/bin/env python3
"""Resolve portable glossary references for this Mac without editing source data."""
import json
import os
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:3])
pack = json.loads(source.read_text(encoding="utf-8"))
root = Path(os.environ.get("LECTURELENS_MOODLE_DIR", str(Path.home() / "Desktop" / "Moodle课程资料"))).expanduser().resolve()
for term in pack["terms"]:
    for reference in term.get("references", []):
        relative = Path(reference["relative"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Glossary reference must remain within the materials folder")
        reference["path"] = str(root / relative)
destination.write_text(json.dumps(pack, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
