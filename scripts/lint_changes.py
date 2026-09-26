#!/usr/bin/env python3
"""Reject added Swift lint debt relative to a reviewed Git base.

Both revisions use the same tools and options. Budgets are per file and rule,
so moving an existing line does not create a violation, new files get no
allowance, and fixing one rule cannot offset adding a different one.
"""

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import tempfile


def added_violations(current, baseline):
    return current - baseline


def collect(root, files):
    counts = Counter()
    if not files:
        return counts
    commands = {
        # SwiftFormat 0.63's collecting JSON reporter crashed in write() on
        # both CI and this Mac. Its default reporter emits each finding directly.
        "swiftformat": ["swiftformat", "--lint", "--cache", "ignore", "--swift-version", "6.0", "--trailing-commas", "never"],
        "swiftlint": ["swiftlint", "lint", "--quiet", "--no-cache", "--reporter", "json"],
    }
    for tool, command in commands.items():
        result = subprocess.run(command + files, cwd=root, text=True, capture_output=True)
        if tool == "swiftformat":
            rows = [{"file": match[1], "rule_id": match[2]} for match in re.finditer(
                r"^(.+):\d+:\d+: (?:error|warning): \(([^)]+)\) ",
                result.stdout + result.stderr, re.MULTILINE
            )]
        else:
            try:
                rows = json.loads(result.stdout)
            except json.JSONDecodeError as error:
                raise RuntimeError(f"{tool} did not return a report ({result.returncode}): {result.stderr}") from error
        if not isinstance(rows, list) or result.returncode not in (0, 1, 2):
            raise RuntimeError(f"{tool} failed ({result.returncode}): {result.stderr}")
        if result.returncode != 0 and not rows:
            raise RuntimeError(f"{tool} failed without reporting violations: {result.stderr}")
        for row in rows:
            path = Path(row["file"])
            if path.is_absolute():
                path = path.resolve().relative_to(root.resolve())
            rule = row.get("rule_id", row.get("rule_identifier"))
            if not rule:
                raise RuntimeError(f"{tool} reported an unidentified rule: {row}")
            counts[(tool, str(path), rule)] += 1
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main")
    args = parser.parse_args()
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    base = subprocess.check_output(
        ["git", "rev-parse", "--verify", args.base + "^{commit}"], cwd=root, text=True
    ).strip()
    files = subprocess.check_output(["git", "ls-files", "-z", "--", "*.swift"], cwd=root).decode().split("\0")
    current = collect(root, [file for file in files if file and (root / file).is_file()])
    base_files = subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", "-z", base], cwd=root
    ).decode().split("\0")
    base_files = [file for file in base_files if file.endswith(".swift")]
    with tempfile.TemporaryDirectory(prefix="brim-lint-") as directory:
        snapshot = Path(directory).resolve()
        for file in base_files:
            target = snapshot / file
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(subprocess.check_output(["git", "show", f"{base}:{file}"], cwd=root))
        baseline = collect(snapshot, base_files)
    additions = added_violations(current, baseline)
    for (tool, file, rule), count in sorted(additions.items()):
        print(f"{file}: {tool} {rule}: {count} added violation(s)")
    print(f"Lint baseline {base[:8]}: {sum(baseline.values())} existing, {sum(current.values())} current, "
          f"{sum(additions.values())} added.")
    return bool(additions)


if __name__ == "__main__":
    raise SystemExit(main())
