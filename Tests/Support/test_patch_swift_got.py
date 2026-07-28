# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCHER = ROOT / "Embedded/swift/main/patch_swift_got.py"
SPEC = importlib.util.spec_from_file_location("patch_swift_got", PATCHER)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PatchSwiftGotTests(unittest.TestCase):
    def run_patcher(self, text: str) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory() as directory:
            linker_script = Path(directory) / "sections.ld"
            linker_script.write_text(text, encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(PATCHER), str(linker_script)],
                capture_output=True,
                check=False,
                text=True,
            )
            return result, linker_script.read_text(encoding="utf-8")

    def test_replaces_exact_pinned_discard_rule(self) -> None:
        result, text = self.run_patcher("before\n" + MODULE.DISCARD_RULE + "after\n")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(text, "before\n" + MODULE.REPLACEMENT + "after\n")

    def test_already_patched_script_is_accepted(self) -> None:
        result, text = self.run_patcher("before\n" + MODULE.REPLACEMENT + "after\n")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(text, "before\n" + MODULE.REPLACEMENT + "after\n")

    def test_missing_rule_fails_closed_without_modifying_file(self) -> None:
        original = "SECTIONS { /DISCARD/ : { *(.comment) } }\n"
        result, text = self.run_patcher(original)

        self.assertEqual(result.returncode, 1)
        self.assertIn("expected one unpatched ESP-IDF v5.4", result.stderr)
        self.assertEqual(text, original)

    def test_duplicate_rule_fails_closed_without_modifying_file(self) -> None:
        original = MODULE.DISCARD_RULE * 2
        result, text = self.run_patcher(original)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(text, original)

    def test_mixed_replacement_and_discard_fails_closed(self) -> None:
        original = MODULE.REPLACEMENT + MODULE.DISCARD_RULE
        result, text = self.run_patcher(original)

        self.assertEqual(result.returncode, 1)
        self.assertEqual(text, original)


if __name__ == "__main__":
    unittest.main()
