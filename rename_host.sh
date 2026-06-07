#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage:"
    echo "  $0 <new-hostname>              — replace TEMPLATE with new hostname"
    echo "  $0 <old-hostname> <new-hostname> — replace old hostname with new"
    exit 1
}

# Validate hostname: only letters, digits, hyphens; no leading/trailing hyphen
validate_hostname() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        echo "Error: invalid hostname '$name'" >&2
        exit 1
    fi
}

safe_sed() {
    local from="$1" to="$2" file="$3"
    [[ -f "$file" ]] || return 0
    sed -i "s/${from}/${to}/g" "$file"
}

if [[ $# -eq 0 ]]; then
    usage
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "Error: run as root or with sudo" >&2
    exit 1
fi

if [[ $# -eq 1 ]]; then
    NEW="$1"
    validate_hostname "$NEW"
    OLD="TEMPLATE"
elif [[ $# -eq 2 ]]; then
    OLD="$1"
    NEW="$2"
    validate_hostname "$OLD"
    validate_hostname "$NEW"
else
    usage
fi

hostnamectl set-hostname "$NEW"
safe_sed "$OLD" "$NEW" /etc/hosts
safe_sed "$OLD" "$NEW" /etc/hostname
safe_sed "$OLD" "$NEW" /etc/mailname
safe_sed "$OLD" "$NEW" /etc/postfix/main.cf

echo "Hostname changed: $OLD → $NEW"
