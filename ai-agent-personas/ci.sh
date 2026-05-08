#!/usr/bin/env bash
set -euo pipefail

echo "Validating personas.json..."
python3 -c "
import json, sys

with open('personas.json') as f:
    data = json.load(f)

required_keys = {'id', 'name', 'emoji', 'description', 'responsibilities', 'tone', 'example_prompt'}
errors = []

for p in data.get('personas', []):
    missing = required_keys - p.keys()
    if missing:
        errors.append(f\"Persona '{p.get('id', '?')}' missing fields: {missing}\")
    if not isinstance(p.get('responsibilities'), list) or len(p['responsibilities']) == 0:
        errors.append(f\"Persona '{p.get('id', '?')}' must have a non-empty responsibilities list\")

if errors:
    for e in errors:
        print('ERROR:', e, file=sys.stderr)
    sys.exit(1)

print(f\"OK: {len(data['personas'])} personas validated.\")
"
