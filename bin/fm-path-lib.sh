#!/usr/bin/env bash
# fm-path-lib.sh - pathname helpers with no source-time side effects, so
# read-only callers can load them without any library's state setup.
#
# fm_dirname_to and fm_basename_to are fork-free: each assigns
# <output-variable> exactly what `$(dirname -- <path>)` or
# `$(basename -- <path>)` would: POSIX component rules, and the command
# substitution's removal of trailing newlines.

fm_dirname_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') fm_path=. ;;
    *[!/]*)
      fm_path=${fm_path%"${fm_path##*[!/]}"}
      case "$fm_path" in
        */*)
          fm_path=${fm_path%/*}
          fm_path=${fm_path%"${fm_path##*[!/]}"}
          [ -n "$fm_path" ] || fm_path=/
          ;;
        *) fm_path=. ;;
      esac
      ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

fm_basename_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') ;;
    *[!/]*) fm_path=${fm_path%"${fm_path##*[!/]}"}; fm_path=${fm_path##*/} ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

# True when <path> lies strictly below <ancestor>, compared as spelled; callers
# pass already-resolved absolute paths.
fm_path_is_ancestor_of() {  # <ancestor> <path>
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

# Print <path> as an absolute directory: an absolute <path> unchanged, a relative
# one resolved physically from the current directory. <name> labels the error.
# Any control byte refuses, so a path cannot smuggle a newline or escape into
# the records and shell text built from it.
fm_resolve_directory_input() {  # <name> <path>
  local name=$1 path=$2 resolved
  local LC_ALL=C
  case "$path" in
    *[[:cntrl:]]*)
      echo "error: $name directory contains an invalid control byte" >&2
      return 1
      ;;
    /*)
      printf '%s\n' "$path"
      return 0
      ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

# The physical path of an existing directory, or empty with status 1.
fm_real_dir() {  # <dir>
  (cd -P -- "$1" 2>/dev/null && pwd -P)
}

# The fully resolved path of an existing file, or empty. Resolution runs in
# node because it must follow a symlink chain to its final target.
fm_real_file() {  # <file>
  node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1" 2>/dev/null
}

# The resolved common dir of a git worktree, or empty. --git-common-dir can be
# relative, so it is resolved from inside the worktree rather than joined here.
fm_git_common_dir() {  # <worktree>
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -P -- "$dir" && fm_real_dir "$common")
}
