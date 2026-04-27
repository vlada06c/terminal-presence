if [[ -z "${TERMINAL_PRESENCE_DIR:-}" ]]; then
  export TERMINAL_PRESENCE_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd
  )"
fi

__terminal_presence_status_file="${TERMINAL_PRESENCE_STATUS_FILE:-/tmp/terminal_presence_status}"

__terminal_presence_write_status() {
  printf 'shell=%s\n%s\n' "${TERMINAL_PRESENCE_SHELL_NAME:-bash}" "$1" > "$__terminal_presence_status_file"
}

__terminal_presence_preexec() {
  [[ -n "${__terminal_presence_in_hook:-}" ]] && return
  __terminal_presence_in_hook=1

  local command="$BASH_COMMAND"

  case "$command" in
    __terminal_presence_* ) __terminal_presence_in_hook=; return ;;
  esac

  if [[ -z "${COMP_LINE:-}" && "$command" != "$PROMPT_COMMAND" ]]; then
    __terminal_presence_write_status "$command"
  fi

  __terminal_presence_in_hook=
}

trap '__terminal_presence_preexec' DEBUG
