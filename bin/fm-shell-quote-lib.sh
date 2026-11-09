#!/usr/bin/env bash
# fm-shell-quote-lib.sh - the one POSIX single-quote encoder for values written
# into generated shell text (hook commands, launch lines, briefs, plists).
# No source-time side effects.

# Print <value> as one single-quoted shell word: every ' becomes '\'' and the
# result is wrapped in '...'. Every byte, including trailing newlines, survives.
fm_shell_quote() {  # <value>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}
