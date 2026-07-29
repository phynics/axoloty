# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Patches the generated ESP-IDF v5.4 linker script immediately before the ELF
# link. Swift's UnicodeDataTables archive requires .got/.got.plt, while the
# pinned ESP-IDF template discards them for GCC-382. This fails closed when the
# pinned template changes or the patch is duplicated.

if(NOT DEFINED LINKER_SCRIPT)
    message(FATAL_ERROR "LINKER_SCRIPT is required")
endif()

set(discard_rule "   *(.got .got.plt) /* TODO: GCC-382 */\n")
set(replacement "   /* Swift UnicodeDataTables requires .got/.got.plt. */\n")

file(READ "${LINKER_SCRIPT}" contents)
string(FIND "${contents}" "${discard_rule}" discard_index)
string(FIND "${contents}" "${replacement}" replacement_index)

if(discard_index EQUAL -1)
    if(replacement_index EQUAL -1)
        message(FATAL_ERROR "expected one unpatched ESP-IDF v5.4 GCC-382 discard rule or one clean replacement")
    endif()
    string(LENGTH "${replacement}" replacement_length)
    math(EXPR replacement_after "${replacement_index} + ${replacement_length}")
    string(SUBSTRING "${contents}" ${replacement_after} -1 remaining)
    string(FIND "${remaining}" "${replacement}" duplicate_replacement_index)
    if(NOT duplicate_replacement_index EQUAL -1)
        message(FATAL_ERROR "expected exactly one Swift GOT replacement")
    endif()
    return()
endif()

if(NOT replacement_index EQUAL -1)
    message(FATAL_ERROR "found both the GCC-382 discard rule and Swift GOT replacement")
endif()

string(LENGTH "${discard_rule}" discard_length)
math(EXPR discard_after "${discard_index} + ${discard_length}")
string(SUBSTRING "${contents}" ${discard_after} -1 remaining)
string(FIND "${remaining}" "${discard_rule}" duplicate_discard_index)
if(NOT duplicate_discard_index EQUAL -1)
    message(FATAL_ERROR "expected exactly one unpatched ESP-IDF v5.4 GCC-382 discard rule")
endif()

string(REPLACE "${discard_rule}" "${replacement}" patched "${contents}")
file(WRITE "${LINKER_SCRIPT}" "${patched}")
