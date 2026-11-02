#!/bin/sh
# Runs the tests with coverage and fails unless every line in
# Sources/ShotPromptCore is covered. Sources/ShotPrompt (the AppKit shell) is
# not measured; see README "Tests".
set -eu
cd "$(dirname "$0")/.."
THRESHOLD="${COVERAGE_THRESHOLD:-100}"

swift test --enable-code-coverage
JSON="$(swift test --show-codecov-path)"

python3 -I - "$JSON" "$PWD/Sources/ShotPromptCore/" "$THRESHOLD" <<'PY'
import json, sys
path, prefix, threshold = sys.argv[1], sys.argv[2], float(sys.argv[3])
files = [f for d in json.load(open(path))["data"] for f in d["files"]
         if f["filename"].startswith(prefix)]
if not files:
    sys.exit(f"coverage: no files under {prefix} in {path}")
count = covered = 0
print(f"{'File':<40} {'Lines':>7} {'Missed':>7} {'Cover':>8}")
for f in sorted(files, key=lambda f: f["filename"]):
    lines = f["summary"]["lines"]
    count += lines["count"]; covered += lines["covered"]
    print(f"{f['filename'][len(prefix):]:<40} {lines['count']:>7} "
          f"{lines['count'] - lines['covered']:>7} {lines['percent']:>7.2f}%")
    # Name the uncovered lines, so a failure says where to look.
    missed = [s[0] for s in f["segments"] if s[3] and s[2] == 0 and s[4]]
    if lines["covered"] < lines["count"] and missed:
        print(f"    uncovered segments start at lines {sorted(set(missed))}")
total = 100.0 * covered / count
print(f"{'TOTAL':<40} {count:>7} {count - covered:>7} {total:>7.2f}%")
if total < threshold:
    sys.exit(f"coverage: {total:.2f}% of lines in Sources/ShotPromptCore is below {threshold:g}%")
print(f"coverage: {total:.2f}% >= {threshold:g}%")
PY
