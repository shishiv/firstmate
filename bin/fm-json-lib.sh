# shellcheck shell=bash
# fm-json-lib.sh - the one JSON string-content encoder for scripts that build
# JSON by hand. No side effects on source.

# Print <text> escaped for use between JSON double quotes: backslash, quote,
# newline, tab, and CR are escaped; any other C0 control byte is dropped.
fm_json_escape() {  # <text>
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}
