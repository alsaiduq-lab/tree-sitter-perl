#! /usr/bin/env perl

use v5.38;
use Path::Tiny qw/path/;
use Unicode::UCD 'prop_invlist';

# prop_invlist returns an array whos odd indices start the include section, and the even
# ones represent the stop. we invert these list so they represent NOT having the quality
my @non_words    = (0, prop_invlist('Word'),         0x10FFFF);
my @non_start    = (0, prop_invlist('XID_Start'),    0x10FFFF);
my @non_continue = (0, prop_invlist('XID_Continue'), 0x10FFFF);

use List::Util   qw/pairmap uniq/;
use Range::Merge qw/merge/;

# we merge the ranges here, so we see all codepoints that don't have the prop
sub merge_with_non_words (@interested_range) {
  my $merged = merge([ pairmap { [ $a => $b ] } @non_words, @interested_range ]);
  # and now we flip it back!
  shift $merged->[0]->@*;
  pop $merged->[-1]->@*;
  my @final = map $_->@*, $merged->@*;
  return @final;
}

sub render_array (@range_pairs) {
  my $rendered = join "\n", '{', join(",\n", pairmap {"  { $a, $b }"} @range_pairs), '}';
}
my @idstart    = merge_with_non_words(@non_start);
my @idcont     = merge_with_non_words(@non_continue);
my @whitespace = prop_invlist 'White_Space';

path('./src/tsp_unicode.h')->spew(<<C);
/* THIS FILE IS GENERATED BY unicode_ranges.pl */

#include "bsearch.c"
#include <stdint.h>
#include <stdbool.h>

struct TSPRange { int32_t start; int32_t end; };
static int tsprange_contains (const void * a, const void * b) {
  struct TSPRange * range = (struct TSPRange*)b;
  int32_t key = *(int32_t*)a;
  if (key < range->start)
    return -1;
  if (key >= range->end)
    return 1;
  return 0;
}

static const struct TSPRange tsp_id_start[] = ${\render_array @idstart};

bool is_tsp_id_start (int32_t codepoint) {
  return bsearch(&codepoint, tsp_id_start, sizeof(tsp_id_start) / sizeof(tsp_id_start[0]), sizeof(tsp_id_start[0]), tsprange_contains);
}

static const struct TSPRange tsp_id_continue[] = ${\render_array @idcont};

bool is_tsp_id_continue (int32_t codepoint) {
  return bsearch(&codepoint, tsp_id_continue, sizeof(tsp_id_continue) / sizeof(tsp_id_continue[0]), sizeof(tsp_id_continue[0]), tsprange_contains);
}

static const struct TSPRange tsp_whitespace[] = ${\render_array @whitespace};
bool is_tsp_whitespace (int32_t codepoint) {
  return bsearch(&codepoint, tsp_whitespace, sizeof(tsp_whitespace) / sizeof(tsp_whitespace[0]), sizeof(tsp_whitespace[0]), tsprange_contains);
}
C

# now we build the JS regexes
use Unicode::UCD qw/charprops_all/;
my @found;
for (1 .. 0x10FFFF) {
  next unless chr =~ /\p{XID_Continue}/ and chr !~ /\p{Word}/;
  push @found, $_;
}
use Range::Merge 'merge_discrete';
my $ranges = merge_discrete \@found;

sub render_js_range ($range) {
  if ($range->[0] == $range->[1]) {
    return sprintf '\u{%x}', $range->[0];
  } else {
    return sprintf '\u{%x}-\u{%x}', $range->[0], $range->[1] - 1;
  }
}
# we had to remove the nonwords b/c it makes WASM compilation die horrifically see https://github.com/tree-sitter/tree-sitter/issues/3496
# my $nonwords = join '', '[', (map { render_js_range $_ } $ranges->@*), ']';
path('./lib/unicode_ranges.js')->spew(<<JS);
// NOTE - this is generated by unicode_ranges.pl
module.exports = {
  // these patterns are simply XID_Start followed by XID_Continue, minus things which don't match perl's \\p{Word}
  identifier: /[_\\p{XID_Start}][\\p{XID_Continue}]*/v,
  // this adds in any amount of :: before or in between identifiers
  bareword:   /((::)|([_\\p{XID_Start}][\\p{XID_Continue}]*))+/v,
}
JS
