#!/usr/bin/env bash
set -u

REPO='nezhahq/agent'
VERSION=''
PLATFORM=''
ARCH=''
AGENT_BASE='/opt/nezha/agent'
AGENT_BIN="${AGENT_BASE}/nezha-agent"
GITHUB_API_URLS=(
  'https://api.github.com'
  'https://githubapi.spiritlhl.workers.dev'
  'https://githubapi.spiritlhl.top'
)
CDN_URLS=(
  'https://cdn0.spiritlhl.top/'
  'http://cdn3.spiritlhl.net/'
  'http://cdn1.spiritlhl.net/'
  'http://cdn2.spiritlhl.net/'
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
  printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$1"
}

log_success() {
  printf '%b[SUCCESS]%b %s\n' "$GREEN" "$NC" "$1"
}

log_warning() {
  printf '%b[WARNING]%b %s\n' "$YELLOW" "$NC" "$1"
}

log_error() {
  printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log_error 'This script must be run as root.'
    exit 1
  fi
}

detect_platform() {
  case "$(uname -s)" in
    Linux)
      PLATFORM='linux'
      ;;
    Darwin)
      PLATFORM='darwin'
      ;;
    *)
      log_error "Unsupported operating system: $(uname -s)"
      exit 1
      ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      ARCH='amd64'
      ;;
    aarch64|arm64|arm64e)
      ARCH='arm64'
      ;;
    s390x)
      ARCH='s390x'
      ;;
    i386|i686)
      ARCH='386'
      ;;
    *)
      log_error "Unsupported architecture: $(uname -m)"
      exit 1
      ;;
  esac
}

ensure_download_tool() {
  if command_exists curl || command_exists wget; then
    return 0
  fi
  log_error 'curl or wget is required.'
  exit 1
}

install_unzip_linux() {
  if command_exists apt-get; then
    apt-get update >/dev/null 2>&1 && apt-get install -y unzip >/dev/null 2>&1 && return 0
  elif command_exists dnf; then
    dnf install -y unzip >/dev/null 2>&1 && return 0
  elif command_exists yum; then
    yum install -y unzip >/dev/null 2>&1 && return 0
  elif command_exists zypper; then
    zypper --non-interactive install unzip >/dev/null 2>&1 && return 0
  elif command_exists apk; then
    apk add --no-cache unzip >/dev/null 2>&1 && return 0
  elif command_exists pacman; then
    pacman -Sy --noconfirm unzip >/dev/null 2>&1 && return 0
  fi
  return 1
}

ensure_unzip() {
  if command_exists unzip; then
    return 0
  fi
  if [ "$PLATFORM" != 'linux' ]; then
    log_error 'unzip is required.'
    exit 1
  fi
  log_info 'Installing unzip...'
  if ! install_unzip_linux; then
    log_error 'Unable to install unzip automatically.'
    exit 1
  fi
}

download_file() {
  local url="$1"
  local output="$2"
  if command_exists curl; then
    curl -fsSL --connect-timeout 10 --max-time 120 -o "$output" "$url" >/dev/null 2>&1 && return 0
  fi
  if command_exists wget; then
    wget -q --timeout=10 --tries=3 -O "$output" "$url" >/dev/null 2>&1 && return 0
  fi
  return 1
}

download_from_candidates() {
  local output="$1"
  shift
  local url
  for url in "$@"; do
    log_info "Trying download source: $url"
    if download_file "$url" "$output"; then
      return 0
    fi
  done
  return 1
}

parse_version_from_api() {
  printf '%s\n' "$1" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

parse_version_from_jsdelivr() {
  printf '%s\n' "$1" | grep -o "${REPO}@[^\"' <]*" | head -n 1 | cut -d'@' -f2
}

get_latest_version() {
  if [ -n "${INSTALL_VERSION:-}" ]; then
    VERSION="$INSTALL_VERSION"
    log_info "Using requested version: $VERSION"
    return 0
  fi

  local api
  local response
  local version
  for api in "${GITHUB_API_URLS[@]}"; do
    log_info "Fetching latest version from ${api}"
    if response=$(curl -fsSL --connect-timeout 10 --max-time 20 -H 'User-Agent: oneclickvirt-nezha-installer' "${api}/repos/${REPO}/releases/latest" 2>/dev/null); then
      version=$(parse_version_from_api "$response")
      if [ -n "$version" ] && [ "$version" != 'null' ]; then
        VERSION="$version"
        log_success "Latest agent version: $VERSION"
        return 0
      fi
    fi
  done

  local jsdelivr_url
  for jsdelivr_url in "https://cdn.jsdelivr.net/gh/${REPO}/" "https://fastly.jsdelivr.net/gh/${REPO}/" "https://gcore.jsdelivr.net/gh/${REPO}/"; do
    log_info "Falling back to CDN version listing: ${jsdelivr_url}"
    if response=$(curl -fsSL --connect-timeout 10 --max-time 20 "$jsdelivr_url" 2>/dev/null); then
      version=$(parse_version_from_jsdelivr "$response")
      if [ -n "$version" ]; then
        VERSION="$version"
        log_success "Latest agent version: $VERSION"
        return 0
      fi
    fi
  done

  log_error 'Unable to determine the latest agent version.'
  return 1
}

build_release_urls() {
  local asset="$1"
  local direct_url="https://github.com/${REPO}/releases/download/${VERSION}/${asset}"
  local cdn
  for cdn in "${CDN_URLS[@]}"; do
    printf '%s\n' "${cdn}${direct_url}"
  done
  printf '%s\n' "$direct_url"
}

install_binary() {
  local asset="nezha-agent_${PLATFORM}_${ARCH}.zip"
  local tmpdir
  tmpdir=$(mktemp -d)
  local archive_path="${tmpdir}/${asset}"
  local urls=()
  local url

  while IFS= read -r url; do
    urls+=("$url")
  done < <(build_release_urls "$asset")

  if ! download_from_candidates "$archive_path" "${urls[@]}"; then
    rm -rf "$tmpdir"
    log_error "Failed to download ${asset}."
    exit 1
  fi

  if ! unzip -qo "$archive_path" -d "$tmpdir" >/dev/null 2>&1; then
    rm -rf "$tmpdir"
    log_error 'Failed to extract the agent archive.'
    exit 1
  fi

  local extracted
  extracted=$(find "$tmpdir" -type f -name 'nezha-agent' | head -n 1)
  if [ -z "$extracted" ]; then
    rm -rf "$tmpdir"
    log_error 'Cannot find nezha-agent in the extracted archive.'
    exit 1
  fi

  mkdir -p "$AGENT_BASE"
  install -m 755 "$extracted" "$AGENT_BIN"
  rm -rf "$tmpdir"
  log_success "Agent binary installed to ${AGENT_BIN}"
}

configure_agent() {
  require_root
  if [ ! -x "$AGENT_BIN" ]; then
    log_error 'Agent binary is not installed yet.'
    exit 1
  fi

  local server_host=''
  local server_port='5555'
  local agent_secret=''
  local extra_args=''
  local tls_choice=''

  if [ $# -ge 3 ]; then
    server_host="$1"
    server_port="$2"
    agent_secret="$3"
    shift 3
    if [ $# -gt 0 ]; then
      extra_args="$*"
    fi
  else
    printf 'Dashboard gRPC host or IP: '
    read -r server_host
    printf 'Dashboard gRPC port [5555]: '
    read -r server_port
    server_port=${server_port:-5555}
    printf 'Agent secret: '
    read -r agent_secret
    printf 'Enable TLS for gRPC? [y/N]: '
    read -r tls_choice
    case "$tls_choice" in
      y|Y|yes|YES)
        extra_args='--tls'
        ;;
    esac
  fi

  if [ -z "$server_host" ] || [ -z "$agent_secret" ]; then
    log_error 'Dashboard host and agent secret are required.'
    exit 1
  fi

  if [ -n "$extra_args" ]; then
    "$AGENT_BIN" service install -s "${server_host}:${server_port}" -p "$agent_secret" $extra_args >/dev/null 2>&1
  else
    "$AGENT_BIN" service install -s "${server_host}:${server_port}" -p "$agent_secret" >/dev/null 2>&1
  fi

  if [ $? -ne 0 ]; then
    "$AGENT_BIN" service uninstall >/dev/null 2>&1 || true
    if [ -n "$extra_args" ]; then
      "$AGENT_BIN" service install -s "${server_host}:${server_port}" -p "$agent_secret" $extra_args >/dev/null 2>&1
    else
      "$AGENT_BIN" service install -s "${server_host}:${server_port}" -p "$agent_secret" >/dev/null 2>&1
    fi
  fi

  if [ $? -ne 0 ]; then
    log_error 'Failed to install or update the agent service.'
    exit 1
  fi

  log_success 'Agent service configured successfully.'
}

install_agent() {
  require_root
  detect_platform
  detect_arch
  ensure_download_tool
  ensure_unzip
  get_latest_version || exit 1
  install_binary
  configure_agent "$@"
}

show_agent_log() {
  if command_exists journalctl; then
    journalctl -u nezha-agent -n 30 --no-pager 2>/dev/null && return 0
  fi
  if [ -f /var/log/nezha-agent.err.log ]; then
    tail -n 30 /var/log/nezha-agent.err.log
    return 0
  fi
  log_warning 'No agent log source was found.'
}

restart_agent() {
  require_root
  if [ ! -x "$AGENT_BIN" ]; then
    log_error 'Agent binary is not installed yet.'
    exit 1
  fi
  "$AGENT_BIN" service restart
}

uninstall_agent() {
  require_root
  if [ -x "$AGENT_BIN" ]; then
    "$AGENT_BIN" service uninstall >/dev/null 2>&1 || true
  fi
  rm -rf "$AGENT_BASE"
  rmdir /opt/nezha >/dev/null 2>&1 || true
  log_success 'Agent removed successfully.'
}

show_usage() {
  cat <<'EOF'
Nezha Agent installer

Usage:
  install_agent [host] [port] [secret] [--tls]
  modify_agent_config [host] [port] [secret] [--tls]
  show_agent_log
  restart_agent
  uninstall_agent
EOF
}

show_menu() {
  cat <<'EOF'
Nezha Agent Management
  1. Install Agent
  2. Modify Agent Configuration
  3. View Agent Log
  4. Restart Agent
  5. Uninstall Agent
  0. Exit
EOF
  printf 'Select an option [0-5]: '
  local choice=''
  read -r choice
  case "$choice" in
    1) install_agent ;;
    2) configure_agent ;;
    3) show_agent_log ;;
    4) restart_agent ;;
    5) uninstall_agent ;;
    0) exit 0 ;;
    *) log_error 'Invalid option.' ;;
  esac
}

main() {
  case "${1:-}" in
    install_agent)
      shift
      install_agent "$@"
      ;;
    modify_agent_config)
      shift
      configure_agent "$@"
      ;;
    show_agent_log)
      show_agent_log
      ;;
    restart_agent)
      restart_agent
      ;;
    uninstall_agent)
      uninstall_agent
      ;;
    help|-h|--help)
      show_usage
      ;;
    '')
      show_menu
      ;;
    *)
      show_usage
      exit 1
      ;;
  esac
}

main "$@"