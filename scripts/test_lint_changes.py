import unittest
from collections import Counter
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch
from lint_changes import added_violations, collect


class LintBaselineTests(unittest.TestCase):
    def test_existing_debt_is_allowed_but_increases_are_not(self):
        key = ("swiftformat", "Old.swift", "indent")
        self.assertFalse(added_violations(Counter({key: 2}), Counter({key: 3})))
        self.assertEqual(added_violations(Counter({key: 4}), Counter({key: 3})), Counter({key: 1}))

    def test_other_files_and_rules_cannot_spend_existing_allowances(self):
        baseline = Counter({("swiftformat", "Old.swift", "indent"): 10})
        current = Counter({("swiftformat", "New.swift", "indent"): 1,
                           ("swiftlint", "Old.swift", "force_cast"): 1})
        self.assertEqual(added_violations(current, baseline), current)

    @patch("lint_changes.subprocess.run")
    def test_tool_failure_cannot_appear_clean(self, run):
        for code, output in [(1, "[]"), (2, "not JSON"), (3, "[]")]:
            with self.subTest(code=code, output=output):
                run.return_value = CompletedProcess([], code, output, "failed")
                with self.assertRaises(RuntimeError):
                    collect(Path.cwd(), ["Example.swift"])

    @patch("lint_changes.subprocess.run")
    def test_reports_keep_tool_and_rule_identity_without_cache(self, run):
        run.side_effect = [
            CompletedProcess([], 1, '[{"file":"Example.swift","rule_id":"indent"}]', ""),
            CompletedProcess([], 2, '[{"file":"Example.swift","rule_identifier":"force_cast"}]', ""),
        ]
        self.assertEqual(collect(Path.cwd(), ["Example.swift"]), Counter({
            ("swiftformat", "Example.swift", "indent"): 1,
            ("swiftlint", "Example.swift", "force_cast"): 1,
        }))
        command = run.call_args_list[0].args[0]
        self.assertEqual(command[command.index("--cache") + 1], "ignore")


if __name__ == "__main__":
    unittest.main()
