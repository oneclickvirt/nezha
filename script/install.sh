#!/usr/bin/env bash
set -e

SCRIPT_REPO='oneclickvirt/nezha'
SCRIPT_BRANCH='v0-final'
RAW_SCRIPT_URL="https://raw.githubusercontent.com/${SCRIPT_REPO}/refs/heads/${SCRIPT_BRANCH}/script/install-agent.sh"
SCRIPT_URLS=(
    "https://cdn0.spiritlhl.top/${RAW_SCRIPT_URL}"
    "http://cdn3.spiritlhl.net/${RAW_SCRIPT_URL}"
    "http://cdn1.spiritlhl.net/${RAW_SCRIPT_URL}"
    "http://cdn2.spiritlhl.net/${RAW_SCRIPT_URL}"
    "${RAW_SCRIPT_URL}"
)

download_core_script() {
    local output="$1"
    local url
    for url in "${SCRIPT_URLS[@]}"; do
        if command -v curl >/dev/null 2>&1 && curl -fsSL --connect-timeout 10 --max-time 60 -o "$output" "$url" >/dev/null 2>&1; then
            return 0
        fi
        if command -v wget >/dev/null 2>&1 && wget -q --timeout=10 --tries=3 -O "$output" "$url" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

main() {
    local tmp_script
    tmp_script=$(mktemp)
    trap 'rm -f "$tmp_script"' EXIT
    if ! download_core_script "$tmp_script"; then
        echo 'Failed to download install-agent.sh from the current repository.' >&2
        exit 1
    fi
    exec bash "$tmp_script" "$@"
}

main "$@"
