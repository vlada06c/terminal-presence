autoload -Uz add-zsh-hook

if [[ -z "${TERMINAL_PRESENCE_DIR:-}" ]]; then
  export TERMINAL_PRESENCE_DIR="${${(%):-%x}:A:h:h}"
fi

terminal_presence_preexec() {
  local status_file="${TERMINAL_PRESENCE_STATUS_FILE:-/tmp/terminal_presence_status}"
  printf 'shell=%s\n%s\n' "${TERMINAL_PRESENCE_SHELL_NAME:-zsh}" "$1" >| "$status_file"
}

add-zsh-hook preexec terminal_presence_preexec
