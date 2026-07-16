# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Regression tests for the GitHub Work Plan Issue Form."""

from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
ISSUE_FORM = REPOSITORY_ROOT / ".github" / "ISSUE_TEMPLATE" / "work-plan.yml"


class WorkPlanIssueFormTests(unittest.TestCase):
    """Verify that the planning template is a validated GitHub Issue Form."""

    def test_requires_all_work_plan_sections(self) -> None:
        """The form collects every section required by the planning workflow."""
        contents = ISSUE_FORM.read_text(encoding="utf-8")

        for field_id in (
            "outcome",
            "in_scope",
            "non_goals",
            "dependencies",
            "design_decisions",
            "implementation_checklist",
            "acceptance_criteria",
            "validation_commands",
        ):
            self.assertIn(f"id: {field_id}", contents)

        self.assertEqual(contents.count("required: true"), 8)


if __name__ == "__main__":
    unittest.main()
