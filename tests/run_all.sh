#!/usr/bin/env bash
# run_all.sh — Execute all test suites for todo.txt-dsl
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

echo "========================================================"
echo "Running Addon Regression Suite (tests/test_addons.sh)..."
echo "========================================================"
bash "$ROOT/tests/test_addons.sh"

echo ""
echo "========================================================"
echo "Running Everyday Usage Suite (tests/test_everyday_usage.sh)..."
echo "========================================================"
bash "$ROOT/tests/test_everyday_usage.sh"

echo ""
echo "========================================================"
echo "Running Conformance Suite (tests/test_conformance.sh)..."
echo "========================================================"
bash "$ROOT/tests/test_conformance.sh"

echo ""
echo "========================================================"
echo "All test suites completed successfully!"
echo "========================================================"
