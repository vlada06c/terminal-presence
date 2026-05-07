#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
)"
SOURCE_DIR="$SCRIPT_DIR"
DEFAULT_INSTALL_DIR="$HOME/.local/share/terminal-presence"
MANAGED_BLOCK_START="# >>> terminal-presence >>>"
MANAGED_BLOCK_END="# <<< terminal-presence <<<"
APP_TITLE="terminal-presence installer"
INSTALL_LOG="$(mktemp -t terminal-presence-install.XXXXXX.log)"
GUI_MODE=0

init_ui() {
  if command -v zenity >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    GUI_MODE=1
  fi
}

show_info() {
  local text="$1"

  if [[ "$GUI_MODE" -eq 1 ]]; then
    zenity --info --title="$APP_TITLE" --width=720 --text="$text"
  else
    printf '%b\n\n' "$text"
  fi
}

show_warning() {
  local text="$1"

  if [[ "$GUI_MODE" -eq 1 ]]; then
    zenity --warning --title="$APP_TITLE" --width=720 --text="$text"
  else
    printf 'Warning: %b\n\n' "$text" >&2
  fi
}

show_error() {
  local text="$1"

  if [[ "$GUI_MODE" -eq 1 ]]; then
    zenity --error --title="$APP_TITLE" --width=720 --text="$text"
  else
    printf 'Error: %b\n' "$text" >&2
  fi
}

die() {
  show_error "$1"
  exit 1
}

expand_path() {
  local input="$1"

  case "$input" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${input#~/}" ;;
    *) printf '%s\n' "$input" ;;
  esac
}

print_header() {
  local text

  text=$'terminal-presence installer\n\nThis installer will:\n- copy extracted files to a permanent install location\n- create or reuse .venv\n- install Python requirements\n- write CLIENT_ID into .env\n- detect your shell and add the hook automatically\n- install and start the user systemd service\n\nIf zenity is available, the installer uses GUI dialogs. Otherwise it falls back to terminal prompts.\n\nWhen asked for Discord App ID:\n1. Open https://discord.com/developers/applications\n2. Create a new application or open an existing one\n3. Open General Information\n4. Copy Application ID and paste it into the installer'
  show_info "$text"
}

validate_repo_dir() {
  local repo_dir="$1"

  if [[ ! -f "$repo_dir/terminal_presence.py" ]]; then
    die "Required file not found:\n$repo_dir/terminal_presence.py"
  fi

  if [[ ! -f "$repo_dir/requirements.txt" ]]; then
    die "Required file not found:\n$repo_dir/requirements.txt"
  fi

  if [[ ! -d "$repo_dir/shell-hooks" ]]; then
    die "Required directory not found:\n$repo_dir/shell-hooks"
  fi
}

prompt_install_dir() {
  local install_dir=""
  local selected_dir=""

  if [[ "$GUI_MODE" -eq 1 ]]; then
    install_dir="$(
      zenity --entry \
        --title="$APP_TITLE" \
        --width=720 \
        --text="Install location\n\nThe makeself archive extracts to a temporary folder first. Choose the permanent install directory that should keep terminal-presence after setup." \
        --entry-text="$DEFAULT_INSTALL_DIR"
    )" || die "Install location selection cancelled."
  else
    read -r -p "Install location [$DEFAULT_INSTALL_DIR]: " install_dir
  fi

  selected_dir="$(expand_path "${install_dir:-$DEFAULT_INSTALL_DIR}")"

  mkdir -p "$selected_dir"
  if ! install_dir="$(cd "$selected_dir" && pwd)"; then
    die "Could not resolve install location:\n$selected_dir"
  fi

  REPO_DIR="$install_dir"
}

copy_payload() {
  if [[ "$SOURCE_DIR" == "$REPO_DIR" ]]; then
    validate_repo_dir "$REPO_DIR"
    return
  fi

  mkdir -p "$REPO_DIR"

  cp -f "$SOURCE_DIR/install.sh" "$REPO_DIR/install.sh"
  chmod +x "$REPO_DIR/install.sh"

  for file in README.md config.json.example requirements.txt terminal_presence.py .env.example .gitignore; do
    if [[ -f "$SOURCE_DIR/$file" ]]; then
      cp -f "$SOURCE_DIR/$file" "$REPO_DIR/$file"
    fi
  done

  mkdir -p "$REPO_DIR/screenshots" "$REPO_DIR/shell-hooks" "$REPO_DIR/systemd"
  cp -a "$SOURCE_DIR/screenshots/." "$REPO_DIR/screenshots/"
  cp -a "$SOURCE_DIR/shell-hooks/." "$REPO_DIR/shell-hooks/"
  cp -a "$SOURCE_DIR/systemd/." "$REPO_DIR/systemd/"

  validate_repo_dir "$REPO_DIR"
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
      die "Unsupported shell: $shell_name\n\nSupported shells: bash, zsh, fish."
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

read_current_client_id() {
  local env_file="$REPO_DIR/.env"

  CURRENT_CLIENT_ID=""
  if [[ -f "$env_file" ]]; then
    CURRENT_CLIENT_ID="$(
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
}

read_client_id() {
  local prompt_text=""
  local client_id=""

  read_current_client_id

  prompt_text=$'Enter Discord App ID\n\nHow to get it:\n1. Open https://discord.com/developers/applications\n2. Create a new application or open an existing one\n3. Open General Information\n4. Copy Application ID\n\nApplication ID = Discord App ID.'
  if [[ -n "$CURRENT_CLIENT_ID" ]]; then
    prompt_text+=$'\n\nThe current value is prefilled. Leave it as-is and press OK to keep it.'
  else
    prompt_text+=$'\n\nYou can leave this empty, but Discord RPC will not connect until CLIENT_ID is set.'
  fi

  if [[ "$GUI_MODE" -eq 1 ]]; then
    client_id="$(
      zenity --entry \
        --title="$APP_TITLE" \
        --width=760 \
        --text="$prompt_text" \
        --entry-text="$CURRENT_CLIENT_ID"
    )" || die "Discord App ID prompt cancelled."
  else
    if [[ -n "$CURRENT_CLIENT_ID" ]]; then
      printf 'Current CLIENT_ID in .env: %s\n' "$CURRENT_CLIENT_ID"
    fi
    read -r -p "Discord App ID${CURRENT_CLIENT_ID:+ [Enter to keep current]}: " client_id
  fi

  if [[ -z "$client_id" ]]; then
    client_id="$CURRENT_CLIENT_ID"
  fi

  CLIENT_ID_VALUE="$client_id"
}

write_env_file() {
  local env_file="$REPO_DIR/.env"
  local tmp_file

  if [[ -z "$CLIENT_ID_VALUE" ]]; then
    show_warning "CLIENT_ID was left empty.\n\nThe service can still start, but Discord RPC will not connect until you add the App ID."
    return
  fi

  tmp_file="$(mktemp)"
  if [[ -f "$env_file" ]]; then
    grep -vE '^(CLIENT_ID|DISCORD_CLIENT_ID|TERMINAL_PRESENCE_CLIENT_ID)=' "$env_file" > "$tmp_file" || true
  fi
  printf 'CLIENT_ID="%s"\n' "$CLIENT_ID_VALUE" >> "$tmp_file"
  mv "$tmp_file" "$env_file"
}

ensure_python_exec() {
  local python_bin=""

  if [[ -x "$REPO_DIR/.venv/bin/python" ]]; then
    PYTHON_EXEC="$REPO_DIR/.venv/bin/python"
    return
  fi

  python_bin="$(command -v python3 || true)"
  if [[ -z "$python_bin" ]]; then
    die "python3 was not found in PATH."
  fi

  "$python_bin" -m venv "$REPO_DIR/.venv"
  PYTHON_EXEC="$REPO_DIR/.venv/bin/python"
}

install_requirements() {
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
    SERVICE_STATUS="written"
    SERVICE_MESSAGE="systemctl is not available. Service file was written only."
    show_warning "$SERVICE_MESSAGE"
    return
  fi

  if ! systemctl --user daemon-reload; then
    SERVICE_STATUS="written"
    SERVICE_MESSAGE="systemd daemon-reload failed.\n\nInspect with:\nsystemctl --user status terminal-presence.service --no-pager -l\ncat ~/.config/systemd/user/terminal-presence.service"
    show_warning "$SERVICE_MESSAGE"
    return
  fi

  if systemctl --user enable --now terminal-presence.service; then
    SERVICE_STATUS="enabled"
    SERVICE_MESSAGE="systemd service enabled and started."
    return
  fi

  SERVICE_STATUS="written"
  SERVICE_MESSAGE="Service file was created, but the service failed to start.\n\nInspect with:\nsystemctl --user status terminal-presence.service --no-pager -l\ncat ~/.config/systemd/user/terminal-presence.service"
  show_warning "$SERVICE_MESSAGE"
}

run_step() {
  local message="$1"
  shift
  local step_pid
  local progress_pid=""
  local status

  printf '%s...\n' "$message"
  "$@" >>"$INSTALL_LOG" 2>&1 &
  step_pid=$!

  if [[ "$GUI_MODE" -eq 1 ]]; then
    (
      echo "10"
      echo "# $message"
      while kill -0 "$step_pid" 2>/dev/null; do
        sleep 0.5
        echo "# $message"
      done
      echo "100"
    ) | zenity \
      --progress \
      --title="$APP_TITLE" \
      --text="$message" \
      --percentage=0 \
      --pulsate \
      --auto-close \
      --no-cancel \
      --width=520 &
    progress_pid=$!
  fi

  if wait "$step_pid"; then
    status=0
  else
    status=$?
  fi

  if [[ -n "$progress_pid" ]]; then
    wait "$progress_pid" || true
  fi

  if [[ $status -ne 0 ]]; then
    show_error "Installation failed during:\n$message\n\nInstaller log: $INSTALL_LOG"
    printf '\nLast log lines from %s:\n' "$INSTALL_LOG" >&2
    tail -n 20 "$INSTALL_LOG" >&2 || true
    exit "$status"
  fi
}

print_summary() {
  local summary

  summary=$'Setup complete.\n\n'
  summary+="Repo: $REPO_DIR"$'\n'
  summary+="Source payload: $SOURCE_DIR"$'\n'
  summary+="Shell: $SHELL_NAME"$'\n'
  summary+="Shell config: $SHELL_RC_FILE"$'\n'
  summary+="Python: $PYTHON_EXEC"$'\n'
  summary+="Service: $HOME/.config/systemd/user/terminal-presence.service"$'\n'

  if [[ "${SERVICE_STATUS:-written}" == "enabled" ]]; then
    summary+=$'systemd: enabled and started\n'
  else
    summary+=$'systemd: service file written\n'
  fi

  summary+=$'\nNext steps:\n'
  summary+="1. Restart your shell or run: exec $SHELL_NAME -l"$'\n'
  summary+=$'2. Make sure the Discord desktop app is running\n'
  summary+=$'3. Run a command and check: systemctl --user status terminal-presence.service\n'
  summary+=$'4. If needed, inspect logs: tail -f ~/.log/terminal-presence.log\n'

  show_info "$summary"
}

main() {
  init_ui
  validate_repo_dir "$SOURCE_DIR"
  print_header
  prompt_install_dir
  run_step "Copying extracted files to the install location" copy_payload
  detect_shell
  setup_shell_paths
  read_client_id
  run_step "Writing CLIENT_ID to .env" write_env_file
  run_step "Creating or reusing .venv" ensure_python_exec
  run_step "Installing Python requirements" install_requirements
  run_step "Updating shell hook" append_shell_block
  run_step "Installing user systemd service" install_service
  print_summary
}

main "$@"
