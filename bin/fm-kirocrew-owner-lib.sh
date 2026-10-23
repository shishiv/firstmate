#!/usr/bin/env bash
# fm-kirocrew-owner-lib.sh - the Kiro Crew dashboard owner's requests, for the
# two scripts the captain runs from his own shell: bin/fm-kirocrew-setup.sh
# (the app install) and bin/fm-kirocrew-primary.sh (the primary's chat).
#
# The owner token comes from `kirocrew token` and is used for these calls only.
# It is never printed, stored, or passed as a command argument: curl reads the
# cookie from a config on stdin, because every local user can read argv in the
# process list. Crew refuses to let its own agents mint a dashboard token, so
# both scripts refuse to run inside a Crew session.
#
# fm_kirocrew_owner_begin <kirocrew-bin> <gateway-url>
#     read the owner token, or print why not and return 1
# fm_kirocrew_owner_call <method> <path> [json]
#     one owner request; sets FM_KIROCREW_OWNER_CODE and FM_KIROCREW_OWNER_BODY
# fm_kirocrew_owner_end
#     forget the token
# Sourcing has no side effects.

FM_KIROCREW_OWNER_TOKEN=
FM_KIROCREW_OWNER_URL=
FM_KIROCREW_OWNER_PORT=
FM_KIROCREW_OWNER_CODE=
FM_KIROCREW_OWNER_BODY=

fm_kirocrew_owner_begin() {  # <kirocrew-bin> <gateway-url>
  local owner_url
  owner_url=$("$1" token 2>/dev/null | grep -o 'https\{0,1\}://[^ ]*token=[^ &#]*' | head -1 || true)
  FM_KIROCREW_OWNER_TOKEN=${owner_url##*token=}
  if [ -z "$owner_url" ] || [ -z "$FM_KIROCREW_OWNER_TOKEN" ]; then
    echo "error: \`kirocrew token\` printed no dashboard token; is the gateway at $2 running?" >&2
    return 1
  fi
  FM_KIROCREW_OWNER_URL=$2
  FM_KIROCREW_OWNER_PORT=$(node -e 'const u=new URL(process.argv[1]); process.stdout.write(u.port || (u.protocol === "https:" ? "443" : "80"))' "$2")
}

fm_kirocrew_owner_call() {  # <method> <path> [json]
  local args=(-sS -K - -X "$1" -w '\n%{http_code}') token=${FM_KIROCREW_OWNER_TOKEN//\\/\\\\} out
  [ $# -lt 3 ] || args+=(-H 'Content-Type: application/json' --data-binary "$3")
  out=$(printf 'header = "Cookie: mc_token_%s=%s"\n' "$FM_KIROCREW_OWNER_PORT" "${token//\"/\\\"}" \
    | curl "${args[@]}" "$FM_KIROCREW_OWNER_URL$2")
  # shellcheck disable=SC2034 # Output globals, read by the sourcing script.
  FM_KIROCREW_OWNER_CODE=${out##*$'\n'}
  # shellcheck disable=SC2034 # Output globals, read by the sourcing script.
  FM_KIROCREW_OWNER_BODY=${out%$'\n'*}
}

fm_kirocrew_owner_end() {
  FM_KIROCREW_OWNER_TOKEN=
}
