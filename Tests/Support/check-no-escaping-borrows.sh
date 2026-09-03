#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

# Guards against the borrowed-bytes lifetime bug documented in
# docs/borrowed-lifetime-audit.md and fixed in 6172052 (wire) and 880ff26
# (protocol): a function or closure that returns one of this codebase's
# non-copying wire/object "view" types (ByteSlice, TopicView,
# BorrowedMessage, BorrowedProtocolFrame, WireValueView, WireReader) as the
# bare, final expression of a withUnsafe*-family trailing closure. Those
# types hold a raw pointer into whatever buffer the withUnsafe* call
# scoped; the pointer is only guaranteed valid for the duration of that
# closure. Handing the constructed view back out as the closure's own
# return value lets it escape into the caller with a pointer that can be
# dangling (a locally-scoped array that is about to go out of scope, as in
# 6172052) or aliased to a different value on the next loop iteration or
# call (a reused stack temporary, as in 880ff26) by the time anyone reads
# it.
#
# This is deliberately narrow, not a blanket ban on withUnsafe*: the
# overwhelming majority of withUnsafe* call sites in this codebase (see
# docs/borrowed-lifetime-audit.md) consume the borrowed bytes entirely
# inside the closure and return a primitive, a copied/owned value, or a
# generic caller-supplied `body` result -- all safe by construction, and
# none of that is flagged here. The rule fires only on the exact shape of
# the two known bugs: `return <expr>.withUnsafeX(...) { ... }` (or the
# free-function `withUnsafeBytes(of:)` / `withUnsafeMutableBytes(of:)`
# spelling) whose trailing closure's last line is a bare
# `TypeName(...)` construction of one of the listed view types, with
# nothing chained after it (a chained `.property`/`.method()` access,
# e.g. the fixed `TopicView(...).eventType`, projects the borrow down to
# a safe primitive before the closure returns and is correctly not
# flagged).
#
# No exemptions are currently required: the audit found zero remaining
# instances of this shape outside the two already-fixed sites. If a
# legitimate construct is ever flagged, add its exact file:line to the
# ALLOWLIST below with a comment explaining why the borrow does not
# actually escape, rather than loosening the pattern.

# ALLOWLIST -- explicit "file:line" exceptions, one per line, with a
# comment above each explaining why it is safe despite matching the
# pattern. Empty by design; see the note above.
ALLOWLIST="
"

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"

search_dirs="Source Packages Tests"
exclude_prefixes="Packages/AxolotyStaticRuntime Tests/AxolotyTests/ProtocolTrace"

scanner="$root/Tests/Support/detect-escaping-borrow.pl"

hits_file=$(mktemp)
trap 'rm -f "$hits_file"' EXIT

for dir in $search_dirs; do
    [ -d "$dir" ] || continue
    find "$dir" -name '*.swift' -type f
done | while IFS= read -r file; do
    skip=0
    for prefix in $exclude_prefixes; do
        case "$file" in
            "$prefix"/*) skip=1 ;;
        esac
    done
    [ "$skip" = 1 ] && continue
    perl "$scanner" "$file" >> "$hits_file" || true
done

found=0
while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    location=$(printf '%s' "$hit" | cut -d: -f1-2)
    allowed=0
    for entry in $ALLOWLIST; do
        [ "$entry" = "$location" ] && allowed=1
    done
    if [ "$allowed" -eq 0 ]; then
        echo "$hit" >&2
        found=1
    fi
done < "$hits_file"

if [ "$found" -ne 0 ]; then
    echo "" >&2
    echo "error: a borrowed wire/object view escapes its withUnsafe* scope (see above)" >&2
    echo "See docs/borrowed-lifetime-audit.md and the header of this script." >&2
    exit 1
fi

echo "no escaping borrowed-view constructions found"
