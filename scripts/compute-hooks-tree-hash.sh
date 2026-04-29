#!/usr/bin/env bash
# compute-hooks-tree-hash.sh — compute the canonical tree hash for a hooks bundle.
#
# Usage:
#   ./scripts/compute-hooks-tree-hash.sh <MODULE_DIR>
#
# MODULE_DIR must contain:
#   hooks.yml          — the root hooks task list
#   hooks/<file> ...   — any Ansible task files referenced from hooks.yml
#
# Algorithm (canonical form, NUL-delimited path+content, lexicographic order):
#   For each file in [hooks.yml] + sorted(hooks/*), where sorting is by the
#   path relative to MODULE_DIR (LC_ALL=C lexicographic; hooks.yml sorts first
#   because '.' < '/'):
#     emit: path_bytes + NUL + content_bytes + NUL
#   SHA-256 the full emitted stream.
#
# Output: 64-character lowercase hex digest followed by a newline.
#
# Vendored from primare-infra (scripts/ci/compute-hooks-tree-hash.sh). The
# algorithm must stay byte-identical with that upstream — the deploy role
# re-runs this same computation against the fetched hooks bundle and asserts
# the digest matches the hooks_tree_sha256 value in ansible/modules.yml.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <MODULE_DIR>" >&2
    exit 1
fi

MODULE_DIR="$1"

if [[ ! -d "$MODULE_DIR" ]]; then
    echo "Error: MODULE_DIR '$MODULE_DIR' does not exist or is not a directory" >&2
    exit 1
fi

if [[ ! -f "$MODULE_DIR/hooks.yml" ]]; then
    echo "Error: '$MODULE_DIR/hooks.yml' not found" >&2
    exit 1
fi

python3 - "$MODULE_DIR" <<'PYEOF'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
hooks_dir = root / "hooks"

# Build candidate list: hooks.yml first, then sorted hooks/* (non-recursive)
candidates = [root / "hooks.yml"]
if hooks_dir.is_dir():
    candidates += sorted(hooks_dir.glob("*"))

# Filter to regular files only
files = [p for p in candidates if p.is_file()]

# Sort by relative path string (LC_ALL=C lexicographic).
# hooks.yml -> "hooks.yml"; hooks/log-fact.yml -> "hooks/log-fact.yml"
# '.' < '/' in ASCII so "hooks.yml" sorts before "hooks/..." — hooks.yml is first.
files.sort(key=lambda p: str(p.relative_to(root)))

h = hashlib.sha256()
for p in files:
    rel = str(p.relative_to(root)).encode()
    content = p.read_bytes()
    h.update(rel)
    h.update(b"\x00")
    h.update(content)
    h.update(b"\x00")

print(h.hexdigest())
PYEOF
