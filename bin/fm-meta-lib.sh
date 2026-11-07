# shellcheck shell=bash
# fm-meta-lib.sh - the one reader of `key=value` task records (state/<id>.meta).
# No side effects on source, so a light script can load it without the
# backend dispatcher.

# fm_meta_get: the LAST value of `key=` in <meta-file>, or empty (never
# errors) if the file or key is absent. The key is matched literally.
fm_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2 line value=''
  [ -f "$meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done < "$meta" 2>/dev/null || true
  printf '%s' "$value"
}
