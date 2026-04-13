#!/usr/bin/env python3
"""Extract the JSON schema block from a DSC resource docs markdown file.

The MicrosoftDocs/PowerShell-Docs-DSC markdown files contain a section called
"## Instance validating schema" with a fenced JSON code block.  This script
extracts that block and writes it to stdout as formatted JSON.

Usage:
  extract_schema_from_md.py <index.md>
"""
import json
import re
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text()

match = re.search(
    r'##\s+Instance validating schema.*?```json\s*(.*?)```',
    content,
    re.DOTALL | re.IGNORECASE,
)
if not match:
    sys.exit(f"ERROR: no 'Instance validating schema' JSON block found in {sys.argv[1]}")

schema = json.loads(match.group(1))

# Windows registry MultiString values are arrays of strings at the DSC layer.
# The upstream schema incorrectly types them as plain strings; fix to array.
try:
    ms = schema["properties"]["valueData"]["properties"]["MultiString"]
    ms["type"] = ["array", "null"]
    ms["items"] = {"type": "string"}
    ms.pop("default", None)
except KeyError:
    pass

print(json.dumps(schema, indent=2))
