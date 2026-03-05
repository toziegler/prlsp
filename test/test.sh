#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Create a temp git repo with source files matching fixture line numbers
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
git init -q
git checkout -q -b feature/test-branch
# Set up a fake GitHub remote
git remote add origin git@github.com:testowner/testrepo.git

mkdir -p src

# Create src/main.py with content at lines matching the fixture (lines 10, 25)
cat > src/main.py << 'PYEOF'
"""Main module."""

import sys


# Some setup code
config = {}


def process_data(data):
    """Process the input data."""
    # line 10 has a review comment about None handling
    result = []
    for item in data:
        result.append(item * 2)
    return result


def transform(items):
    """Transform items."""
    pass


def collect_results(source):
    """Collect results from source."""
    # line 25 has a review comment about list comprehension
    output = []
    for x in source:
        output.append(x)
    return output


def main():
    data = [1, 2, 3]
    print(process_data(data))


if __name__ == "__main__":
    main()
PYEOF

# Create src/utils.py with content at lines matching the fixture (lines 5, 42)
cat > src/utils.py << 'PYEOF'
"""Utility functions."""

import os
import sys
import json  # line 5: unused import review comment
from pathlib import Path


def read_file(path):
    """Read a file and return contents."""
    with open(path) as f:
        return f.read()


def write_file(path, content):
    """Write content to a file."""
    with open(path, "w") as f:
        f.write(content)


def ensure_dir(path):
    """Ensure directory exists."""
    os.makedirs(path, exist_ok=True)


def parse_config(text):
    """Parse configuration text."""
    return json.loads(text)


def format_output(data):
    """Format data for output."""
    return str(data)


def validate_input(value):
    """Validate input value."""
    # line 42: resolved comment about typo (should not show)
    if value is None:
        raise ValueError("Input cannot be None")
    return value


def helper():
    """Helper function."""
    pass
PYEOF

git add -A
git commit -q -m "initial commit"

echo "=== prlsp test environment ==="
echo "Temp repo: $TMPDIR"
echo "Branch: $(git rev-parse --abbrev-ref HEAD)"
echo ""
echo "Launching nvim with mock data..."
echo "  - src/main.py should have 2 diagnostics (lines 10, 25)"
echo "  - src/utils.py should have 1 diagnostic (line 5)"
echo ""
echo "Keys:"
echo "  ]d / [d  — navigate diagnostics"
echo "  <space>e — show diagnostic float"
echo "  gra      — code action (normal or visual mode)"
echo "  :PrlspRefresh — re-fetch threads"
echo ""

export PYTHONPATH="$PROJECT_DIR:${PYTHONPATH:-}"
export PRLSP_MOCK="$PROJECT_DIR/test/fixtures/comments.json"

nvim --clean -u "$PROJECT_DIR/test/init.lua" src/main.py
