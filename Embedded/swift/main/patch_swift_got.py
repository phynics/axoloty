# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Keep Swift Unicode GOT/PLT sections in ESP-IDF v5.4's generated script."""

from pathlib import Path
import sys


DISCARD_RULE = "   *(.got .got.plt) /* TODO: GCC-382 */\n"
REPLACEMENT = "   /* Swift UnicodeDataTables requires .got/.got.plt. */\n"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_swift_got.py <generated-sections.ld>", file=sys.stderr)
        return 2

    linker_script = Path(sys.argv[1])
    text = linker_script.read_text(encoding="utf-8")
    discard_count = text.count(DISCARD_RULE)
    replacement_count = text.count(REPLACEMENT)
    if discard_count == 0 and replacement_count == 1:
        return 0
    if discard_count != 1 or replacement_count != 0:
        print(
            "Swift GOT patch failed: expected one unpatched ESP-IDF v5.4 "
            "GCC-382 discard rule or one clean replacement",
            file=sys.stderr,
        )
        return 1

    linker_script.write_text(
        text.replace(DISCARD_RULE, REPLACEMENT),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
