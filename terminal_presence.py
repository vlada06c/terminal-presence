#!/usr/bin/env python3
"""Discord Rich Presence bridge for terminal activity."""

from __future__ import annotations

import json
import logging
import os
import platform
import pwd
import re
import shlex
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from pypresence import Presence

DEFAULT_ENV_PATH = Path(__file__).with_name(".env")
DEFAULT_CONFIG_PATH = Path(__file__).with_name("config.json")

DEFAULT_CONFIG: dict[str, Any] = {
    "status_file": "/tmp/terminal_presence_status",
    "update_interval": 3,
    "discord_poll_interval": 10,
    "reconnect_delay": 5,
    "stale_status_seconds": 20,
    "max_state_length": 128,
    "max_command_length": 120,
    "idle_details": "Idle in terminal",
    "shell_name": "",
    "log_file": "~/.log/terminal-presence.log",
    "discord_assets": {
        "large_image": "terminal",
        "large_text": "{os_name} Terminal",
        "small_image": "",
        "small_text": "{shell_name} shell",
    },
    "custom_commands": [],
}

BLACKLIST = {
    "ls",
    "ll",
    "la",
    "cd",
    "pwd",
    "clear",
    "cls",
    "exit",
    "source",
    "history",
    "whoami",
    "date",
    "cat",
    "echo",
}

WRAPPER_COMMANDS = {
    "sudo",
    "doas",
    "env",
    "command",
    "builtin",
    "nohup",
    "time",
    "nice",
    "ionice",
    "stdbuf",
    "setsid",
}

EDITOR_COMMANDS = {"nano", "vim", "nvim", "micro", "hx", "helix"}
MONITOR_COMMANDS = {"htop", "btop", "bpytop", "top", "iotop"}
TRANSFER_COMMANDS = {"scp", "rsync", "sftp"}
FETCH_COMMANDS = {"curl", "wget", "http", "xh"}
CONTAINER_COMMANDS = {"docker", "podman", "docker-compose", "compose"}
SERVICE_COMMANDS = {"systemctl", "journalctl", "service"}
PACKAGE_COMMANDS = {"apt", "apt-get", "dnf", "yum", "pacman", "yay", "paru"}
PERMISSION_COMMANDS = {"chmod", "chown", "chgrp"}
PYTHON_COMMANDS = {"python", "python3", "uv", "poetry", "pip", "pip3"}
NODE_COMMANDS = {"node", "npm", "pnpm", "yarn", "bun"}

LOGGER = logging.getLogger("terminal_presence")


@dataclass
class CustomRule:
    pattern: str
    details: str
    state: str
    match_type: str = "contains"
    case_sensitive: bool = False
    regex: re.Pattern[str] | None = None


@dataclass
class StatusSnapshot:
    command: str = ""
    shell_name: str = ""


@dataclass
class Settings:
    client_id: str
    status_file: Path
    update_interval: int
    discord_poll_interval: int
    reconnect_delay: int
    stale_status_seconds: int
    max_state_length: int
    max_command_length: int
    idle_details: str
    shell_name_override: str
    log_file: Path
    os_name: str
    large_image: str | None
    large_text: str
    small_image: str | None
    small_text: str
    custom_commands: list[CustomRule]


def expand_path(path_value: str) -> Path:
    return Path(path_value).expanduser()


def merge_config(defaults: dict[str, Any], overrides: dict[str, Any]) -> dict[str, Any]:
    merged = dict(defaults)
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = merge_config(merged[key], value)
        else:
            merged[key] = value
    return merged


def load_env_file(path: Path) -> tuple[dict[str, str], list[str]]:
    values: dict[str, str] = {}
    warnings: list[str] = []

    if not path.exists():
        return values, warnings

    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return values, [f"Failed to read {path}: {exc}"]

    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            warnings.append(f"Ignoring invalid .env entry at line {line_number}: {raw_line!r}")
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if not key:
            warnings.append(f"Ignoring empty .env key at line {line_number}")
            continue
        values[key] = value

    return values, warnings


def load_json_config(path: Path) -> tuple[dict[str, Any], list[str]]:
    if not path.exists():
        return {}, []

    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return {}, [f"Failed to load {path}: {exc}"]

    if not isinstance(loaded, dict):
        return {}, [f"Ignoring {path}: top-level JSON value must be an object"]

    return loaded, []


def detect_os_name() -> str:
    os_release = Path("/etc/os-release")
    if os_release.exists():
        try:
            for line in os_release.read_text(encoding="utf-8").splitlines():
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
        except OSError:
            pass

    return platform.system()


def normalize_shell_name(value: str) -> str:
    cleaned = value.strip()
    if not cleaned:
        return ""
    return Path(cleaned).name or cleaned


def detect_shell_name(status_shell: str, override: str) -> str:
    candidates = [
        override,
        status_shell,
        os.environ.get("TERMINAL_PRESENCE_SHELL", ""),
        os.environ.get("SHELL", ""),
    ]

    try:
        candidates.append(pwd.getpwuid(os.getuid()).pw_shell)
    except KeyError:
        pass

    for candidate in candidates:
        shell_name = normalize_shell_name(candidate)
        if shell_name:
            return shell_name

    return "shell"


def resolve_client_id(env_values: dict[str, str]) -> str:
    keys = ("CLIENT_ID", "DISCORD_CLIENT_ID", "TERMINAL_PRESENCE_CLIENT_ID")
    for key in keys:
        value = os.environ.get(key) or env_values.get(key, "")
        if value:
            return value
    return ""


def parse_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def build_custom_rules(raw_rules: Any) -> tuple[list[CustomRule], list[str]]:
    warnings: list[str] = []
    built_rules: list[CustomRule] = []

    if not raw_rules:
        return built_rules, warnings

    if not isinstance(raw_rules, list):
        return built_rules, ["Ignoring custom_commands: expected a list"]

    for index, raw_rule in enumerate(raw_rules, start=1):
        if not isinstance(raw_rule, dict):
            warnings.append(f"Ignoring custom_commands[{index}]: expected an object")
            continue

        pattern = str(raw_rule.get("pattern", "")).strip()
        details = str(raw_rule.get("details", "")).strip()
        state = str(raw_rule.get("state", "{command}")).strip() or "{command}"
        match_type = str(raw_rule.get("match", "contains")).strip().lower() or "contains"
        case_sensitive = bool(raw_rule.get("case_sensitive", False))

        if not pattern or not details:
            warnings.append(
                f"Ignoring custom_commands[{index}]: pattern and details are required"
            )
            continue

        if match_type not in {"contains", "exact", "regex"}:
            warnings.append(
                f"Ignoring custom_commands[{index}]: unsupported match type {match_type!r}"
            )
            continue

        regex = None
        if match_type == "regex":
            flags = 0 if case_sensitive else re.IGNORECASE
            try:
                regex = re.compile(pattern, flags)
            except re.error as exc:
                warnings.append(f"Ignoring custom_commands[{index}]: invalid regex: {exc}")
                continue

        built_rules.append(
            CustomRule(
                pattern=pattern,
                details=details,
                state=state,
                match_type=match_type,
                case_sensitive=case_sensitive,
                regex=regex,
            )
        )

    return built_rules, warnings


def load_settings() -> tuple[Settings, list[str]]:
    dotenv_values, env_warnings = load_env_file(DEFAULT_ENV_PATH)
    config_values, config_warnings = load_json_config(DEFAULT_CONFIG_PATH)
    merged = merge_config(DEFAULT_CONFIG, config_values)
    assets = merged.get("discord_assets", {})
    custom_rules, rule_warnings = build_custom_rules(merged.get("custom_commands"))

    settings = Settings(
        client_id=resolve_client_id(dotenv_values),
        status_file=expand_path(str(merged.get("status_file", DEFAULT_CONFIG["status_file"]))),
        update_interval=parse_int(merged.get("update_interval"), DEFAULT_CONFIG["update_interval"]),
        discord_poll_interval=parse_int(
            merged.get("discord_poll_interval"), DEFAULT_CONFIG["discord_poll_interval"]
        ),
        reconnect_delay=parse_int(
            merged.get("reconnect_delay"), DEFAULT_CONFIG["reconnect_delay"]
        ),
        stale_status_seconds=parse_int(
            merged.get("stale_status_seconds"), DEFAULT_CONFIG["stale_status_seconds"]
        ),
        max_state_length=parse_int(
            merged.get("max_state_length"), DEFAULT_CONFIG["max_state_length"]
        ),
        max_command_length=parse_int(
            merged.get("max_command_length"), DEFAULT_CONFIG["max_command_length"]
        ),
        idle_details=str(merged.get("idle_details", DEFAULT_CONFIG["idle_details"])),
        shell_name_override=str(merged.get("shell_name", "")).strip(),
        log_file=expand_path(str(merged.get("log_file", DEFAULT_CONFIG["log_file"]))),
        os_name=detect_os_name(),
        large_image=str(assets.get("large_image", "")).strip() or None,
        large_text=str(
            assets.get("large_text", DEFAULT_CONFIG["discord_assets"]["large_text"])
        ),
        small_image=str(assets.get("small_image", "")).strip() or None,
        small_text=str(
            assets.get("small_text", DEFAULT_CONFIG["discord_assets"]["small_text"])
        ),
        custom_commands=custom_rules,
    )

    warnings = env_warnings + config_warnings + rule_warnings
    if not settings.client_id:
        warnings.append(
            "Discord CLIENT_ID is not set. Define it in .env or an environment variable."
        )

    return settings, warnings


def setup_logging(log_path: Path) -> None:
    LOGGER.setLevel(logging.INFO)
    LOGGER.handlers.clear()
    LOGGER.propagate = False

    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")

    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(log_path, encoding="utf-8")
        file_handler.setFormatter(formatter)
        LOGGER.addHandler(file_handler)
    except OSError:
        stream_handler = logging.StreamHandler()
        stream_handler.setFormatter(formatter)
        LOGGER.addHandler(stream_handler)
        LOGGER.exception("Failed to initialize log file at %s", log_path)


def clean_command(command: str, max_length: int) -> str:
    command = " ".join(command.strip().split())
    if not command:
        return ""

    home = os.path.expanduser("~")
    command = command.replace(home, "~")

    for secret_flag in ("--token", "--password", "--pass", "-p"):
        command = command.replace(f"{secret_flag} ", f"{secret_flag} [redacted] ")

    if len(command) > max_length:
        command = command[: max_length - 3] + "..."

    return command


def parse_command(command: str) -> list[str]:
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


def skip_option_with_value(tokens: list[str], index: int, options: set[str]) -> int:
    if tokens[index] in options and index + 1 < len(tokens):
        return index + 2
    return index + 1


def unwrap_command(tokens: list[str]) -> str:
    index = 0

    while index < len(tokens):
        token = tokens[index]

        if token in {"sudo", "doas"}:
            index += 1
            while index < len(tokens):
                current = tokens[index]
                if current == "--":
                    index += 1
                    break
                if not current.startswith("-"):
                    break
                index = skip_option_with_value(
                    tokens,
                    index,
                    {"-u", "-g", "-h", "-p", "-C", "-c", "-r", "-t", "-T", "-U", "-D"},
                )
            continue

        if token == "env":
            index += 1
            while index < len(tokens):
                current = tokens[index]
                if "=" in current and current.index("=") > 0:
                    index += 1
                    continue
                if current in {"-u", "--unset"} and index + 1 < len(tokens):
                    index += 2
                    continue
                if current.startswith("-"):
                    index += 1
                    continue
                break
            continue

        if token in {"time", "command", "builtin", "nohup", "setsid"}:
            index += 1
            continue

        if token in {"nice", "ionice", "stdbuf"}:
            index += 1
            while index < len(tokens):
                current = tokens[index]
                if current == "--":
                    index += 1
                    break
                if not current.startswith("-"):
                    break
                index = skip_option_with_value(tokens, index, {"-n", "-c", "-t", "-o", "-e", "-i"})
            continue

        if token in WRAPPER_COMMANDS:
            index += 1
            continue

        if "=" in token and not token.startswith(("/", "./", "../")) and token.index("=") > 0:
            index += 1
            continue

        return token

    return ""


def format_text(template: str, context: dict[str, str], fallback: str) -> str:
    try:
        return template.format(**context)
    except (KeyError, ValueError):
        return fallback


def matches_custom_rule(rule: CustomRule, command: str) -> bool:
    if rule.match_type == "regex":
        return bool(rule.regex and rule.regex.search(command))

    source = command if rule.case_sensitive else command.lower()
    pattern = rule.pattern if rule.case_sensitive else rule.pattern.lower()

    if rule.match_type == "exact":
        return source == pattern

    return pattern in source


def apply_custom_rule(command: str, context: dict[str, str], rules: list[CustomRule]) -> tuple[str, str] | None:
    for rule in rules:
        if matches_custom_rule(rule, command):
            details = format_text(rule.details, context, rule.details)
            state = format_text(rule.state, context, command)
            return details, state
    return None


def parse_status_content(content: str) -> StatusSnapshot:
    stripped = content.strip()
    if not stripped:
        return StatusSnapshot()

    try:
        payload = json.loads(stripped)
    except json.JSONDecodeError:
        payload = None

    if isinstance(payload, dict):
        command = str(payload.get("command", "")).strip()
        shell_name = str(payload.get("shell", "")).strip()
        return StatusSnapshot(command=command, shell_name=shell_name)

    lines = stripped.splitlines()
    if lines and lines[0].startswith("shell="):
        shell_name = lines[0].split("=", 1)[1].strip()
        command = "\n".join(lines[1:]).strip()
        return StatusSnapshot(command=command, shell_name=shell_name)

    return StatusSnapshot(command=stripped)


def read_status(settings: Settings) -> StatusSnapshot:
    try:
        stat_result = settings.status_file.stat()
    except (FileNotFoundError, OSError):
        return StatusSnapshot()

    if time.time() - stat_result.st_mtime > settings.stale_status_seconds:
        return StatusSnapshot()

    try:
        content = settings.status_file.read_text(encoding="utf-8")
    except OSError as exc:
        LOGGER.warning("Failed to read status file %s: %s", settings.status_file, exc)
        return StatusSnapshot()

    return parse_status_content(content)


def discord_running() -> bool:
    try:
        result = subprocess.run(
            ["pgrep", "-f", "Discord"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError as exc:
        LOGGER.warning("Failed to check Discord process: %s", exc)
        return False

    return bool(result.stdout.strip())


def connect_rpc(settings: Settings) -> Presence | None:
    if not settings.client_id:
        return None

    if not discord_running():
        return None

    try:
        rpc = Presence(settings.client_id)
        rpc.connect()
        LOGGER.info("Connected to Discord RPC")
        return rpc
    except Exception:
        LOGGER.exception("Failed to connect to Discord RPC")
        return None


def close_rpc(rpc: Presence | None) -> None:
    if rpc is None:
        return

    try:
        rpc.close()
    except Exception:
        LOGGER.exception("Failed to close Discord RPC cleanly")


def get_context(snapshot: StatusSnapshot, settings: Settings) -> tuple[str, str]:
    shell_name = detect_shell_name(snapshot.shell_name, settings.shell_name_override)
    cleaned = clean_command(snapshot.command, settings.max_command_length)
    base_context = {
        "command": cleaned,
        "shell_name": shell_name,
        "os_name": settings.os_name,
    }
    idle_state = format_text(settings.small_text, base_context, f"{shell_name} shell")

    if not cleaned:
        return settings.idle_details, idle_state

    custom_match = apply_custom_rule(cleaned, base_context, settings.custom_commands)
    if custom_match:
        return custom_match

    tokens = parse_command(cleaned)
    first_token = tokens[0] if tokens else ""
    base_command = unwrap_command(tokens)

    if not base_command or base_command in BLACKLIST:
        return settings.idle_details, idle_state

    if base_command == "ssh":
        return "Remote Access", cleaned

    if base_command in {"nmap", "masscan", "rustscan"} or "proxychains4 nmap" in cleaned.lower():
        return "Recon Mode", cleaned

    if base_command == "proxychains4":
        return "Proxy Chain Active", cleaned

    if base_command in EDITOR_COMMANDS:
        return "Editing Files", cleaned

    if base_command in PYTHON_COMMANDS:
        return "Running Python", cleaned

    if base_command == "git":
        if " push" in f" {cleaned}":
            return "Shipping Code", cleaned
        if " commit" in f" {cleaned}":
            return "Committing Changes", cleaned
        if " status" in f" {cleaned}":
            return "Checking Repository", cleaned
        return "Working with Git", cleaned

    if first_token in {"sudo", "doas", "su"} and base_command in {"", "bash", "sh", "fish", "zsh"}:
        return "Root Mode Engaged", cleaned

    if base_command == "su":
        return "Root Mode Engaged", cleaned

    if base_command in MONITOR_COMMANDS:
        return "Monitoring System", cleaned

    if base_command in PACKAGE_COMMANDS:
        return "Updating System", cleaned

    if base_command in TRANSFER_COMMANDS:
        return "Transferring Files", cleaned

    if base_command in FETCH_COMMANDS:
        return "Fetching Data", cleaned

    if base_command in CONTAINER_COMMANDS:
        return "Container Work", cleaned

    if base_command in PERMISSION_COMMANDS:
        return "Changing Permissions", cleaned

    if base_command in SERVICE_COMMANDS:
        return "Managing Services", cleaned

    if base_command in {"tmux", "screen", "zellij"}:
        return "Terminal Multiplexing", cleaned

    if base_command in {"kubectl", "helm"}:
        return "Cluster Operations", cleaned

    if base_command in NODE_COMMANDS:
        return "Running JavaScript", cleaned

    return "Using Terminal", cleaned


def build_presence_payload(details: str, state: str, shell_name: str, settings: Settings) -> dict[str, Any]:
    context = {
        "details": details,
        "state": state,
        "shell_name": shell_name,
        "os_name": settings.os_name,
    }

    payload: dict[str, Any] = {
        "details": details,
        "state": state[: settings.max_state_length],
        "large_text": format_text(settings.large_text, context, settings.os_name),
    }

    if settings.large_image:
        payload["large_image"] = settings.large_image

    if settings.small_image:
        payload["small_image"] = settings.small_image

    small_text = format_text(settings.small_text, context, f"{shell_name} shell")
    if small_text:
        payload["small_text"] = small_text

    return payload


def main() -> None:
    settings, warnings = load_settings()
    setup_logging(settings.log_file)

    for warning in warnings:
        LOGGER.warning(warning)

    LOGGER.info("Watching status file %s", settings.status_file)

    rpc = None
    last_payload = None
    activity_started_at = int(time.time())

    while True:
        if rpc is None:
            rpc = connect_rpc(settings)
            if rpc is None:
                time.sleep(settings.discord_poll_interval)
                continue

        try:
            snapshot = read_status(settings)
            shell_name = detect_shell_name(snapshot.shell_name, settings.shell_name_override)
            details, state = get_context(snapshot, settings)
            payload = (details, state, shell_name)

            if payload != last_payload:
                activity_started_at = int(time.time())
                last_payload = payload

            rpc.update(
                start=activity_started_at,
                **build_presence_payload(details, state, shell_name, settings),
            )
        except Exception:
            LOGGER.exception("Failed during presence update loop")
            close_rpc(rpc)
            rpc = None
            time.sleep(settings.reconnect_delay)
            continue

        time.sleep(settings.update_interval)


if __name__ == "__main__":
    main()
