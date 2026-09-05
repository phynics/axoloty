#!/usr/bin/env perl
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Scans one Swift file for the exact shape described in
# check-no-escaping-borrows.sh: a `return <expr>.withUnsafeX(...) { ... }`
# (or free-function `withUnsafeBytes(of: ...) { ... }`) trailing closure
# whose last statement, before the closure's own matching closing brace, is
# a bare `TypeName(...)` construction of one of the non-copying borrowed
# wire/object view types -- nothing chained after it. Prints one
# "file:line: message" hit per line to stdout for each match; prints
# nothing and exits 0 when the file is clean.
#
# This is intentionally a narrow textual heuristic, not a Swift parser. It
# tracks brace depth (after stripping `//` line comments) starting from the
# closure's own opening brace to find that *specific* closure's matching
# closing brace -- not just the next line that happens to be a bare "}",
# which is wrong as soon as the closure body contains its own nested
# blocks (guard/do-catch/if, as in ProtocolExecutor+Outbound.swift). See
# docs/borrowed-lifetime-audit.md for the reasoning and the many withUnsafe*
# call sites this deliberately does not flag.

use strict;
use warnings;

my $file = shift @ARGV or die "usage: $0 <swift-file>\n";
open(my $fh, '<', $file) or die "cannot open $file: $!\n";
my @lines = <$fh>;
close $fh;

my @borrowed_types = qw(
    ByteSlice
    TopicView
    BorrowedMessage
    BorrowedProtocolFrame
    WireValueView
    WireReader
);
my $types_re = join('|', @borrowed_types);

my $open_re = qr/
    return \s+
    (?: try [!?]? \s+ )?
    (?: \S+ \. )?
    withUnsafe \w* \s*
    (?: \( [^\n]* \) \s* )?
    \{
    \s*
    (?: [\w,\s]+ \bin\s* )?
    $
/x;

sub strip_comment {
    my ($line) = @_;
    # Naive `//` line-comment stripping. Does not understand string
    # literals; good enough for brace-counting in this codebase's style
    # (no `//` inside the wire/object code this check scans).
    $line =~ s{//.*$}{};
    return $line;
}

for (my $i = 0; $i < @lines; $i++) {
    next unless $lines[$i] =~ $open_re;

    my $open_text = strip_comment($lines[$i]);
    my $brace_pos = rindex($open_text, '{');
    next if $brace_pos < 0;

    my $depth = 0;
    my ($close_line_idx, $close_pos);
    my $limit = $i + 400 < $#lines ? $i + 400 : $#lines;
    OUTER: for (my $j = $i; $j <= $limit; $j++) {
        my $text = strip_comment($lines[$j]);
        my $start = ($j == $i) ? $brace_pos : 0;
        for (my $p = $start; $p < length($text); $p++) {
            my $ch = substr($text, $p, 1);
            $depth++ if $ch eq '{';
            $depth-- if $ch eq '}';
            if ($depth == 0) {
                $close_line_idx = $j;
                $close_pos = $p;
                last OUTER;
            }
        }
    }
    next unless defined $close_line_idx;
    next if $close_line_idx == $i; # closure opened and closed on one line: no room for a distinct escaping last statement

    my $close_text = strip_comment($lines[$close_line_idx]);
    my $before_brace = substr($close_text, 0, $close_pos);
    $before_brace =~ s/^\s+//;
    $before_brace =~ s/\s+$//;

    my $last_stmt;
    if ($before_brace ne '') {
        $last_stmt = $before_brace;
    } else {
        my $k = $close_line_idx - 1;
        while ($k > $i && strip_comment($lines[$k]) =~ /^\s*$/) { $k--; }
        next if $k <= $i;
        $last_stmt = strip_comment($lines[$k]);
        $last_stmt =~ s/^\s+//;
        $last_stmt =~ s/\s+$//;
    }

    # Match a leading `[return] [try[!?]] TypeName(` and then, starting at
    # that constructor call's own opening paren, walk forward counting
    # balanced parens to find where *that* call closes. Only flag it when
    # nothing but the matched call itself occupies the rest of the
    # statement -- a chained `.property`/`.method()` after the closing
    # paren (e.g. the fixed `TopicView(...).eventType`) means the borrow is
    # projected down to a safe value before the closure returns, and must
    # not be flagged.
    if ($last_stmt =~ /^(?:return\s+)?(?:try[!?]?\s+)?($types_re)\(/) {
        my $type = $1;
        my $open_pos = index($last_stmt, '(', index($last_stmt, $type));
        my $pdepth = 0;
        my $pclose;
        for (my $p = $open_pos; $p < length($last_stmt); $p++) {
            my $ch = substr($last_stmt, $p, 1);
            $pdepth++ if $ch eq '(';
            $pdepth-- if $ch eq ')';
            if ($pdepth == 0) { $pclose = $p; last; }
        }
        if (defined $pclose && $pclose == length($last_stmt) - 1) {
            my $lineno = $i + 1;
            print "$file:$lineno: closure returns a bare $type(...) construction escaping its withUnsafe* scope\n";
        }
    }
}

exit 0;
