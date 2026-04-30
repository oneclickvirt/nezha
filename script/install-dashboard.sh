#!/usr/bin/env bash
set -u

REPO='oneclickvirt/nezha'
SCRIPT_BRANCH='v0-final'
VERSION=''
ARCH=''
APP_DIR='/opt/nezha/dashboard'
DATA_DIR=''
BIN_PATH=''
CONFIG_PATH=''
COMPOSE_PATH=''
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
    *)
      log_error "Unsupported dashboard architecture: $(uname -m)"
      exit 1
      ;;
  esac
}

ensure_linux() {
  if [ "$(uname -s)" != 'Linux' ]; then
    log_error 'The dashboard installer currently supports Linux only.'
    exit 1
  fi
}

ensure_download_tool() {
  if command_exists curl || command_exists wget; then
    return 0
  fi
  log_error 'curl or wget is required.'
  exit 1
}

install_unzip() {
  if command_exists unzip; then
    return 0
  fi
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
  log_error 'Unable to install unzip automatically.'
  exit 1
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
        log_success "Latest dashboard version: $VERSION"
        return 0
      fi
    fi
  done

  local jsdelivr_url
  for jsdelivr_url in "https://cdn.jsdelivr.net/gh/${REPO}/" "https://fastly.jsdelivr.net/gh/${REPO}/" "https://gcore.jsdelivr.net/gh/${REPO}/"; do
    if response=$(curl -fsSL --connect-timeout 10 --max-time 20 "$jsdelivr_url" 2>/dev/null); then
      version=$(parse_version_from_jsdelivr "$response")
      if [ -n "$version" ]; then
        VERSION="$version"
        log_success "Latest dashboard version: $VERSION"
        return 0
      fi
    fi
  done

  log_error 'Unable to determine the latest dashboard version.'
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

build_repo_file_urls() {
  local relative_path="$1"
  local direct_url="https://raw.githubusercontent.com/${REPO}/refs/heads/${SCRIPT_BRANCH}/${relative_path}"
  local cdn
  for cdn in "${CDN_URLS[@]}"; do
    printf '%s\n' "${cdn}${direct_url}"
  done
  printf '%s\n' "$direct_url"
}

escape_sed() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

prompt_default() {
  local prompt="$1"
  local var_name="$2"
  local default_value="$3"
  local current_value="${!var_name:-}"

  if [ -n "$current_value" ]; then
    return 0
  fi
  if [ "${noninteractive:-false}" = 'true' ]; then
    printf -v "$var_name" '%s' "$default_value"
    return 0
  fi

  printf '%s [%s]: ' "$prompt" "$default_value"
  read -r current_value
  printf -v "$var_name" '%s' "${current_value:-$default_value}"
}

prompt_required() {
  local prompt="$1"
  local var_name="$2"
  local current_value="${!var_name:-}"

  while [ -z "$current_value" ]; do
    if [ "${noninteractive:-false}" = 'true' ]; then
      log_error "Missing required environment variable: ${var_name}"
      exit 1
    fi
    printf '%s: ' "$prompt"
    read -r current_value
  done
  printf -v "$var_name" '%s' "$current_value"
}

prompt_yes_no() {
  local prompt="$1"
  local var_name="$2"
  local default_value="$3"
  local current_value="${!var_name:-}"
  local normalized_default='N'
  if [ "$default_value" = 'true' ]; then
    normalized_default='Y'
  fi

  if [ -n "$current_value" ]; then
    return 0
  fi
  if [ "${noninteractive:-false}" = 'true' ]; then
    printf -v "$var_name" '%s' "$default_value"
    return 0
  fi

  printf '%s [y/N]: ' "$prompt"
  if [ "$normalized_default" = 'Y' ]; then
    printf '\b\b[Y/n]: '
  fi
  read -r current_value
  case "$current_value" in
    y|Y|yes|YES)
      printf -v "$var_name" '%s' 'true'
      ;;
    n|N|no|NO)
      printf -v "$var_name" '%s' 'false'
      ;;
    '')
      printf -v "$var_name" '%s' "$default_value"
      ;;
    *)
      printf -v "$var_name" '%s' "$default_value"
      ;;
  esac
}

collect_config_values() {
  prompt_default 'Site title' NZ_SITE_TITLE 'Nezha Monitoring'
  prompt_default 'Language' NZ_LANGUAGE 'zh-CN'
  prompt_default 'Dashboard HTTP port' NZ_HTTP_PORT '80'
  prompt_default 'Dashboard gRPC port' NZ_GRPC_PORT '5555'
  if [ -z "${NZ_GRPC_HOST:-}" ] && [ "${noninteractive:-false}" != 'true' ]; then
    printf 'Public gRPC host or domain (optional, used for agent install hints): '
    read -r NZ_GRPC_HOST
  fi
  prompt_default 'Proxy gRPC port' NZ_PROXY_GRPC_PORT '0'
  prompt_default 'OAuth2 type' NZ_OAUTH2_TYPE 'github'
  prompt_required 'Admin login list (comma separated)' NZ_ADMIN_LOGINS
  prompt_required 'OAuth2 client id' NZ_OAUTH2_CLIENT_ID
  prompt_required 'OAuth2 client secret' NZ_OAUTH2_CLIENT_SECRET
  if [ -z "${NZ_OAUTH2_ENDPOINT:-}" ] && [ "${noninteractive:-false}" != 'true' ]; then
    printf 'OAuth2 endpoint (optional, for custom providers): '
    read -r NZ_OAUTH2_ENDPOINT
  fi
  prompt_yes_no 'Enable TLS for gRPC' NZ_ENABLE_TLS 'false'
}

install_binary() {
  local asset="dashboard-linux-${ARCH}.zip"
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
    log_error 'Failed to extract the dashboard archive.'
    exit 1
  fi

  local extracted
  extracted=$(find "$tmpdir" -type f -name 'dashboard-*' | head -n 1)
  if [ -z "$extracted" ]; then
    rm -rf "$tmpdir"
    log_error 'Cannot find the dashboard binary in the extracted archive.'
    exit 1
  fi

  mkdir -p "$APP_DIR"
  install -m 755 "$extracted" "$BIN_PATH"
  rm -rf "$tmpdir"
  log_success "Dashboard binary installed to ${BIN_PATH}"
}

download_repo_file() {
  local relative_path="$1"
  local output_path="$2"
  local urls=()
  local url
  while IFS= read -r url; do
    urls+=("$url")
  done < <(build_repo_file_urls "$relative_path")

  if ! download_from_candidates "$output_path" "${urls[@]}"; then
    log_error "Failed to download ${relative_path}."
    exit 1
  fi
}

render_config() {
  local tmp_config
  tmp_config=$(mktemp)
  download_repo_file 'script/config.yaml' "$tmp_config"

  sed \
    -e "s/nz_site_title/$(escape_sed "$NZ_SITE_TITLE")/g" \
    -e "s/nz_language/$(escape_sed "$NZ_LANGUAGE")/g" \
    -e "s/nz_site_port/${NZ_HTTP_PORT}/g" \
    -e "s/nz_grpc_port/${NZ_GRPC_PORT}/g" \
    -e "s/nz_grpc_host/$(escape_sed "${NZ_GRPC_HOST:-}")/g" \
    -e "s/nz_proxy_grpc_port/${NZ_PROXY_GRPC_PORT}/g" \
    -e "s/nz_tls/${NZ_ENABLE_TLS}/g" \
    -e "s/nz_oauth2_type/$(escape_sed "$NZ_OAUTH2_TYPE")/g" \
    -e "s/nz_admin_logins/$(escape_sed "$NZ_ADMIN_LOGINS")/g" \
    -e "s/nz_github_oauth_client_id/$(escape_sed "$NZ_OAUTH2_CLIENT_ID")/g" \
    -e "s/nz_github_oauth_client_secret/$(escape_sed "$NZ_OAUTH2_CLIENT_SECRET")/g" \
    -e "s/nz_oauth2_endpoint/$(escape_sed "${NZ_OAUTH2_ENDPOINT:-}")/g" \
    "$tmp_config" > "$CONFIG_PATH"

  rm -f "$tmp_config"
  chmod 600 "$CONFIG_PATH"
  log_success "Config created at ${CONFIG_PATH}"
}

render_compose_template() {
  local tmp_compose
  tmp_compose=$(mktemp)
  download_repo_file 'script/docker-compose.yaml' "$tmp_compose"

  sed \
    -e "s#nz_image_url#ghcr.io/oneclickvirt/nezha-dashboard:${VERSION}#g" \
    -e "s/nz_site_port/${NZ_HTTP_PORT:-80}/g" \
    -e "s/nz_grpc_port/${NZ_GRPC_PORT:-5555}/g" \
    "$tmp_compose" > "$COMPOSE_PATH"

  rm -f "$tmp_compose"
}

install_service_definition() {
  if command_exists systemctl; then
    download_repo_file 'script/nezha-dashboard.service' /etc/systemd/system/nezha-dashboard.service
    chmod 644 /etc/systemd/system/nezha-dashboard.service
    systemctl daemon-reload
    return 0
  fi
  if command_exists rc-service; then
    download_repo_file 'script/nezha-dashboard' /etc/init.d/nezha-dashboard
    chmod 755 /etc/init.d/nezha-dashboard
    return 0
  fi
  log_warning 'No supported service manager found. Install the service manually if needed.'
}

restart_service() {
  if command_exists systemctl; then
    systemctl enable nezha-dashboard >/dev/null 2>&1 || true
    systemctl restart nezha-dashboard >/dev/null 2>&1 || systemctl start nezha-dashboard >/dev/null 2>&1 || true
    return 0
  fi
  if command_exists rc-service; then
    rc-update add nezha-dashboard default >/dev/null 2>&1 || true
    rc-service nezha-dashboard restart >/dev/null 2>&1 || rc-service nezha-dashboard start >/dev/null 2>&1 || true
  fi
}

prepare_environment() {
  require_root
  ensure_linux
  detect_arch
  ensure_download_tool
  install_unzip
  get_latest_version || exit 1
  DATA_DIR="${APP_DIR}/data"
  BIN_PATH="${APP_DIR}/app"
  CONFIG_PATH="${DATA_DIR}/config.yaml"
  COMPOSE_PATH="${APP_DIR}/docker-compose.yaml"
}

show_help() {
  cat <<'EOF'
Nezha Dashboard installer

Usage:
  install-dashboard.sh [install|upgrade|env|help]

Environment variables:
  INSTALL_VERSION=v0.0.0
  noninteractive=true
  NZ_SITE_TITLE=Nezha Monitoring
  NZ_LANGUAGE=zh-CN
  NZ_HTTP_PORT=80
  NZ_GRPC_PORT=5555
  NZ_GRPC_HOST=panel.example.com
  NZ_PROXY_GRPC_PORT=0
  NZ_ENABLE_TLS=false
  NZ_OAUTH2_TYPE=github
  NZ_ADMIN_LOGINS=admin
  NZ_OAUTH2_CLIENT_ID=xxxx
  NZ_OAUTH2_CLIENT_SECRET=xxxx
  NZ_OAUTH2_ENDPOINT=
EOF
}

show_info() {
  cat <<EOF
Install complete.
  Version: ${VERSION}
  Binary: ${BIN_PATH}
  Config: ${CONFIG_PATH}
  Compose template: ${COMPOSE_PATH}

If you need to change OAuth2 or port settings later, edit ${CONFIG_PATH} and restart the service.
EOF
}

install_dashboard() {
  prepare_environment
  mkdir -p "$APP_DIR" "$DATA_DIR"
  install_binary
  if [ ! -f "$CONFIG_PATH" ]; then
    collect_config_values
    render_config
  else
    log_info "Existing config found at ${CONFIG_PATH}, keeping it unchanged."
  fi
  render_compose_template
  install_service_definition
  restart_service
  show_info
}

upgrade_dashboard() {
  prepare_environment
  mkdir -p "$APP_DIR" "$DATA_DIR"
  install_binary
  render_compose_template
  install_service_definition
  restart_service
  show_info
}

env_check() {
  prepare_environment
  log_success "Environment ready. Latest dashboard version: ${VERSION}"
}

case "${1:-install}" in
  install)
    install_dashboard
    ;;
  upgrade)
    upgrade_dashboard
    ;;
  env)
    env_check
    ;;
  help|-h|--help)
    show_help
    ;;
  *)
    show_help
    exit 1
    ;;
esac