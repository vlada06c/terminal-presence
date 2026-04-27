#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
)"
DEFAULT_REPO_DIR="$SCRIPT_DIR"
MANAGED_BLOCK_START="# >>> terminal-presence >>>"
MANAGED_BLOCK_END="# <<< terminal-presence <<<"

print_header() {
  cat <<'EOF'
terminal-presence installer

Discord Client ID:
1. Open https://discord.com/developers/applications
2. Create or open your Discord application
3. Copy the Application ID from General Information
4. Paste that value here when the installer asks for it

The installer will:
- create or reuse .venv
- install Python requirements
- write CLIENT_ID into .env
- detect your shell and add the hook automatically
- install and start the user systemd service
EOF
  printf '\n'
}

expand_path() {
  local input="$1"

  case "$input" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${input#~/}" ;;
    *) printf '%s\n' "$input" ;;
  esac
}

prompt_repo_dir() {
  local repo_dir=""
  local selected_dir=""

  read -r -p "Repository path [$DEFAULT_REPO_DIR]: " repo_dir
  selected_dir="$(expand_path "${repo_dir:-$DEFAULT_REPO_DIR}")"

  if ! repo_dir="$(cd "$selected_dir" && pwd)"; then
    printf 'Error: could not resolve repository path: %s\n' "$selected_dir" >&2
    exit 1
  fi

  if [[ ! -f "$repo_dir/terminal_presence.py" ]]; then
    printf 'Error: required file not found: %s/terminal_presence.py\n' "$repo_dir" >&2
    exit 1
  fi

  if [[ ! -f "$repo_dir/requirements.txt" ]]; then
    printf 'Error: required file not found: %s/requirements.txt\n' "$repo_dir" >&2
    exit 1
  fi

  if [[ ! -d "$repo_dir/shell-hooks" ]]; then
    printf 'Error: required directory not found: %s/shell-hooks\n' "$repo_dir" >&2
    exit 1
  fi

  REPO_DIR="$repo_dir"
}

detect_shell() {
  local shell_name=""

  if [[ -n "${SHELL:-}" ]]; then
    shell_name="$(basename "$SHELL")"
  fi

  if [[ -z "$shell_name" || "$shell_name" == "sh" ]]; then
    if command -v getent >/dev/null 2>&1; then
      shell_name="$(basename "$(getent passwd "$USER" | cut -d: -f7)")"
    fi
  fi

  case "$shell_name" in
    bash|zsh|fish) ;;
    *)
      printf 'Error: unsupported shell %s. Supported shells: bash, zsh, fish.\n' "$shell_name" >&2
      exit 1
      ;;
  esac

  SHELL_NAME="$shell_name"
}

setup_shell_paths() {
  case "$SHELL_NAME" in
    bash)
      SHELL_RC_FILE="$HOME/.bashrc"
      SHELL_SOURCE_LINE='source "$TERMINAL_PRESENCE_DIR/shell-hooks/terminal_presence.bash"'
      ;;
    zsh)
      SHELL_RC_FILE="$HOME/.zshrc"
      SHELL_SOURCE_LINE='source "$TERMINAL_PRESENCE_DIR/shell-hooks/terminal_presence.zsh"'
      ;;
    fish)
      SHELL_RC_FILE="$HOME/.config/fish/config.fish"
      SHELL_SOURCE_LINE='source "$TERMINAL_PRESENCE_DIR/shell-hooks/terminal_presence.fish"'
      ;;
  esac
}

read_client_id() {
  local env_file="$REPO_DIR/.env"
  local current_client_id=""
  local client_id=""

  if [[ -f "$env_file" ]]; then
    current_client_id="$(
      awk -F= '
        $1 == "CLIENT_ID" {
          value = substr($0, index($0, "=") + 1)
          gsub(/^["'"'"']|["'"'"']$/, "", value)
          print value
          exit
        }
      ' "$env_file"
    )"
  fi

  if [[ -n "$current_client_id" ]]; then
    printf 'Current CLIENT_ID in .env: %s\n' "$current_client_id"
  fi

  read -r -p "Discord Client ID${current_client_id:+ [Enter to keep current]}: " client_id
  if [[ -z "$client_id" ]]; then
    client_id="$current_client_id"
  fi

  CLIENT_ID_VALUE="$client_id"
}

write_env_file() {
  local env_file="$REPO_DIR/.env"
  local tmp_file

  if [[ -z "$CLIENT_ID_VALUE" ]]; then
    printf 'Warning: CLIENT_ID was left empty. The service will start, but Discord RPC will not connect.\n'
    return
  fi

  tmp_file="$(mktemp)"
  if [[ -f "$env_file" ]]; then
    grep -vE '^(CLIENT_ID|DISCORD_CLIENT_ID|TERMINAL_PRESENCE_CLIENT_ID)=' "$env_file" > "$tmp_file" || true
  fi
  printf 'CLIENT_ID="%s"\n' "$CLIENT_ID_VALUE" >> "$tmp_file"
  mv "$tmp_file" "$env_file"
}

ensure_virtualenv() {
  local python_bin=""

  if [[ -x "$REPO_DIR/.venv/bin/python" ]]; then
    PYTHON_EXEC="$REPO_DIR/.venv/bin/python"
  else
    python_bin="$(command -v python3 || true)"
    if [[ -z "$python_bin" ]]; then
      printf 'Error: python3 was not found in PATH.\n' >&2
      exit 1
    fi

    "$python_bin" -m venv "$REPO_DIR/.venv"
    PYTHON_EXEC="$REPO_DIR/.venv/bin/python"
  fi

  "$PYTHON_EXEC" -m pip install -r "$REPO_DIR/requirements.txt"
}

strip_managed_block() {
  local file="$1"
  local tmp_file

  [[ -f "$file" ]] || return 0
  grep -qF "$MANAGED_BLOCK_START" "$file" || return 0

  tmp_file="$(mktemp)"
  awk -v start="$MANAGED_BLOCK_START" -v end="$MANAGED_BLOCK_END" '
    $0 == start {skip = 1; next}
    $0 == end {skip = 0; next}
    !skip {print}
  ' "$file" > "$tmp_file"
  mv "$tmp_file" "$file"
}

append_shell_block() {
  local rc_dir

  rc_dir="$(dirname "$SHELL_RC_FILE")"
  mkdir -p "$rc_dir"
  touch "$SHELL_RC_FILE"
  strip_managed_block "$SHELL_RC_FILE"

  if [[ "$SHELL_NAME" == "fish" ]]; then
    cat >> "$SHELL_RC_FILE" <<EOF

$MANAGED_BLOCK_START
set -gx TERMINAL_PRESENCE_DIR "$REPO_DIR"
$SHELL_SOURCE_LINE
$MANAGED_BLOCK_END
EOF
  else
    cat >> "$SHELL_RC_FILE" <<EOF

$MANAGED_BLOCK_START
export TERMINAL_PRESENCE_DIR="$REPO_DIR"
$SHELL_SOURCE_LINE
$MANAGED_BLOCK_END
EOF
  fi
}

install_service() {
  local service_dir="$HOME/.config/systemd/user"
  local service_file="$service_dir/terminal-presence.service"

  mkdir -p "$service_dir"
  cat > "$service_file" <<EOF
[Unit]
Description=Discord terminal presence bridge
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
WorkingDirectory=${REPO_DIR}
ExecStart=${REPO_DIR}/.venv/bin/python ${REPO_DIR}/terminal_presence.py
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=TERMINAL_PRESENCE_DIR=${REPO_DIR}

[Install]
WantedBy=default.target
EOF

  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'Warning: systemctl is not available. Service file was written to %s\n' "$service_file"
    return
  fi

  if ! systemctl --user daemon-reload; then
    SERVICE_STATUS="written"
    printf '\nWarning: systemd daemon-reload failed.\n'
    printf 'Inspect with:\n'
    printf 'systemctl --user status terminal-presence.service --no-pager -l\n'
    printf 'cat ~/.config/systemd/user/terminal-presence.service\n\n'
    return
  fi

  if systemctl --user enable --now terminal-presence.service; then
    SERVICE_STATUS="enabled"
    return
  fi

  SERVICE_STATUS="written"
  printf '\nWarning: systemd service file was created, but the service failed to start.\n'
  printf 'Inspect with:\n'
  printf 'systemctl --user status terminal-presence.service --no-pager -l\n'
  printf 'cat ~/.config/systemd/user/terminal-presence.service\n\n'
}

print_summary() {
  printf '\nSetup complete.\n'
  printf 'Repo: %s\n' "$REPO_DIR"
  printf 'Shell: %s\n' "$SHELL_NAME"
  printf 'Shell config: %s\n' "$SHELL_RC_FILE"
  printf 'Python: %s\n' "$PYTHON_EXEC"
  printf 'Service: %s/.config/systemd/user/terminal-presence.service\n' "$HOME"

  if [[ "${SERVICE_STATUS:-written}" == "enabled" ]]; then
    printf 'systemd: enabled and started\n'
  else
    printf 'systemd: service file written\n'
  fi

  printf '\nNext steps:\n'
  printf '1. Restart your shell or run: exec %s -l\n' "$SHELL_NAME"
  printf '2. Make sure the Discord desktop app is running\n'
  printf '3. Run a command and check: systemctl --user status terminal-presence.service\n'
  printf '4. If needed, inspect logs: tail -f ~/.log/terminal-presence.log\n'
}

main() {
  print_header
  prompt_repo_dir
  detect_shell
  setup_shell_paths
  read_client_id
  write_env_file
  ensure_virtualenv
  append_shell_block
  install_service
  print_summary
}

main "$@"
