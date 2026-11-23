#!/usr/bin/env bash
# profile.sh — Linux environment setup, split into two layers:
#
#   system layer  — packages, binaries, Node (NodeSource), uv, oh-my-zsh, tmux
#                   config, shared zsh settings. Installed once per machine.
#   user layer    — ~/.zshrc, symlinks, ~/.tmux.conf.local, nvim config, login
#                   shell. No packages, almost no network. Run for every user.
#
# Default: system layer only if it is not installed yet (marker file), then
# the user layer for whoever runs the script. Run it as yourself, then as root
# (`sudo -i` → `./profile.sh`) — the second run only does the user layer.
set -euo pipefail

# === Settings =================================================================

NODE_MAJOR="${NODE_MAJOR:-26}"   # NodeSource major version (LTS)

SHARE_DIR=/usr/local/share/profile
SYSTEM_MARKER="$SHARE_DIR/.system-installed"
COMMON_ZSH="$SHARE_DIR/common.zsh"
SHARED_VIMRC="$SHARE_DIR/vimrc"
OMZ_DIR=/opt/oh-my-zsh
TMUX_DIR=/opt/tmux

VIMRC_URL="https://raw.githubusercontent.com/mas-kon/profile/main/vimrc"
NVIM_CONFIG_REPO="https://github.com/mas-kon/nvim"

# === Constants ================================================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# $USER may be unset in containers; guard against `set -u`.
USER="${USER:-$(id -un 2>/dev/null || true)}"

# sudo may keep the caller's HOME — then root would write into someone else's
# home and leave root-owned files there. Always use the real home of $USER.
REAL_HOME=$(getent passwd "$USER" | cut -d: -f6)
if [[ -n "$REAL_HOME" && "$HOME" != "$REAL_HOME" ]]; then
    echo "Note: HOME=$HOME does not belong to $USER, using $REAL_HOME instead."
    export HOME="$REAL_HOME"
fi

LOG_FILE="$HOME/profile_install_${TIMESTAMP}.log"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/profile-install.XXXXXX")
cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# === Architecture detection ===================================================

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH_DEB="amd64";  ARCH_RPM="x86_64";  ARCH_NVIM="x86_64"; ARCH_GO="x86_64";  ARCH_TRIPLE="x86_64" ;;
    aarch64) ARCH_DEB="arm64";  ARCH_RPM="aarch64"; ARCH_NVIM="arm64";  ARCH_GO="arm64";   ARCH_TRIPLE="aarch64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# === Logging ==================================================================

LOG_CAPTURED=0

log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    if [[ "$LOG_CAPTURED" -eq 1 ]]; then
        echo "$msg"
    else
        echo "$msg" | tee -a "$LOG_FILE"
    fi
}

log_error() {
    local msg="[$(date '+%H:%M:%S')] ERROR: $*"
    if [[ "$LOG_CAPTURED" -eq 1 ]]; then
        echo "$msg" >&2
    else
        echo "$msg" | tee -a "$LOG_FILE" >&2
    fi
}

start_log_capture() {
    exec > >(tee -a "$LOG_FILE") 2>&1
    LOG_CAPTURED=1
}

# === Utilities ================================================================

# Run a command as root: directly when already root, otherwise via sudo.
as_root() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

validate_github_api_response() {
    local response="$1"
    local tool_name="$2"

    if ! echo "$response" | jq empty 2>/dev/null; then
        log_error "Invalid JSON response from GitHub API for $tool_name."
        return 1
    fi

    local api_message
    api_message=$(echo "$response" | jq -r '.message // empty')
    if [[ -n "$api_message" ]]; then
        log_error "GitHub API error for $tool_name: $api_message"
        return 1
    fi
}

check_url_exists() {
    local url="$1"
    if ! curl -fsSL --head "$url" -o /dev/null 2>/dev/null; then
        log_error "URL not accessible: $url"
        return 1
    fi
}

# Backup a file or directory before modifying it. Only backs up once per run.
declare -A _BACKED_UP=()
backup_config() {
    local target="$1"
    [[ -e "$target" ]] || return 0
    [[ -n "${_BACKED_UP[$target]:-}" ]] && return 0

    local backup="${target}.bak.${TIMESTAMP}"
    cp -r "$target" "$backup"
    log "Backed up $target → $backup"
    _BACKED_UP[$target]=1
}

# Clone a repo as root into a shared dir, or fast-forward it if already there.
# Files are made world-readable so every user can source them.
root_git_sync() {
    local repo="$1" dir="$2"
    if [[ -d "$dir/.git" ]]; then
        as_root git -C "$dir" pull --ff-only || return 1
    else
        as_root git clone --depth 1 "$repo" "$dir" || return 1
    fi
    as_root chmod -R u=rwX,go=rX "$dir"
}

# === Distro abstraction =======================================================

DISTRO_FAMILY=""

detect_distro() {
    if [[ ! -f /etc/os-release ]]; then
        echo "Error: /etc/os-release not found. Cannot detect distribution." >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu|linuxmint|pop|kali|raspbian) DISTRO_FAMILY="debian" ;;
        fedora)                                    DISTRO_FAMILY="fedora" ;;
        rhel|centos|rocky|almalinux|ol)            DISTRO_FAMILY="rhel" ;;
        *)
            case "${ID_LIKE:-}" in
                *debian*|*ubuntu*) DISTRO_FAMILY="debian" ;;
                *fedora*|*rhel*)   DISTRO_FAMILY="rhel" ;;
                *)
                    log_error "Unsupported distribution: ${PRETTY_NAME:-$ID}"
                    exit 1 ;;
            esac ;;
    esac

    log "Detected distribution: ${PRETTY_NAME:-$ID} (family: $DISTRO_FAMILY)"
}

pkg_update() {
    case "$DISTRO_FAMILY" in
        debian)      as_root apt-get update ;;
        fedora|rhel) as_root dnf makecache ;;
    esac
}

pkg_install() {
    case "$DISTRO_FAMILY" in
        # confdef/confold: keep locally modified config files instead of
        # stopping at dpkg's "keep or replace?" prompt.
        debian)      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                         -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" ;;
        fedora|rhel) as_root dnf install -y "$@" ;;
    esac
}

# Map canonical package name to distro-specific name(s).
# Returns empty string if the package should be skipped on this distro.
pkg_name() {
    local canonical="$1"
    case "$DISTRO_FAMILY" in
        debian)
            case "$canonical" in
                python3)         echo "python3-full python3-venv python3-pip" ;;
                dns-tools)       echo "dnsutils" ;;
                dev-tools)       echo "build-essential" ;;
                ca-certs)        echo "ca-certificates apt-transport-https" ;;
                *)               echo "$canonical" ;;
            esac ;;
        fedora|rhel)
            case "$canonical" in
                dns-tools)       echo "bind-utils" ;;
                dev-tools)       echo "" ;;  # handled via groupinstall
                fonts-powerline) echo "powerline-fonts" ;;
                ca-certs)        echo "" ;;  # built-in
                *)               echo "$canonical" ;;
            esac ;;
    esac
}

install_packages() {
    local packages=("$@")
    [[ ${#packages[@]} -eq 0 ]] && return
    log "Installing packages: ${packages[*]}"
    if pkg_install "${packages[@]}"; then
        return
    fi
    # One unavailable package fails the whole batch — retry one by one so the
    # rest still lands (common on RHEL where EPEL coverage differs).
    log "Bulk install failed, retrying packages individually..."
    local failed=() pkg
    for pkg in "${packages[@]}"; do
        if ! pkg_install "$pkg"; then
            failed+=("$pkg")
            log_error "Package not available: $pkg"
        fi
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "Failed to install packages: ${failed[*]}"
        return 1
    fi
}

# === Bootstrap ================================================================

bootstrap_deps() {
    local missing=() tool
    [[ "$EUID" -eq 0 ]] || command -v sudo &>/dev/null || missing+=(sudo)
    for tool in curl jq git gpg; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    log "Installing required tools: ${missing[*]}..."
    if [[ "$EUID" -ne 0 ]] && ! command -v sudo &>/dev/null; then
        # No sudo yet — fall back to su (asks for root's password).
        case "$DISTRO_FAMILY" in
            debian)      su -c "apt-get update && apt-get install -y ${missing[*]}" ;;
            fedora|rhel) su -c "dnf install -y ${missing[*]}" ;;
        esac
    else
        { pkg_update && pkg_install "${missing[@]}"; } || true
    fi

    for tool in curl jq git gpg; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "Required tool '$tool' could not be installed; install it manually and rerun."
            return 1
        fi
    done
}

ensure_sudo() {
    [[ "$EUID" -eq 0 ]] && return 0
    sudo -n true 2>/dev/null && return 0
    if ! sudo -v; then
        log_error "sudo is not available for user $USER. Run the script as root or grant sudo access, then rerun."
        exit 1
    fi
}

# =============================================================================
# === SYSTEM LAYER ============================================================
# =============================================================================

sys_base_packages() {
    log "Installing base packages..."

    # Enable EPEL before resolving packages — many tools live there on RHEL
    if [[ "$DISTRO_FAMILY" == "fedora" || "$DISTRO_FAMILY" == "rhel" ]]; then
        log "Enabling EPEL repository..."
        as_root dnf install -y epel-release || log "Warning: epel-release not available (may already be enabled)."
        as_root dnf install -y epel-next-release 2>/dev/null || true
    fi

    local canonical_packages=(
        tree mc bat zsh curl wget tmux vim htop git
        chrony sysstat ncdu duf jq ripgrep net-tools
        dns-tools iotop gpg parted fonts-powerline
        python3 dev-tools ca-certs
    )

    local resolved=() pkg resolved_name
    for pkg in "${canonical_packages[@]}"; do
        resolved_name=$(pkg_name "$pkg")
        # shellcheck disable=SC2206  # multi-word names split on purpose
        [[ -n "$resolved_name" ]] && resolved+=($resolved_name)
    done

    pkg_update || log "Warning: package cache update failed, continuing."
    install_packages "${resolved[@]}"

    if [[ "$DISTRO_FAMILY" == "fedora" || "$DISTRO_FAMILY" == "rhel" ]]; then
        log "Installing Development Tools group..."
        as_root dnf groupinstall -y "Development Tools"
    fi
    pkg_install gping || log "Warning: gping not available, skipping."

    log "Base packages installed."
}

sys_lazygit() {
    log "Installing lazygit..."

    local response version
    response=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest")
    validate_github_api_response "$response" "Lazygit" || return 1
    version=$(echo "$response" | jq -r '.tag_name' | sed 's/^v//')
    if [[ -z "$version" || "$version" == "null" ]]; then
        log_error "Could not retrieve latest Lazygit version."
        return 1
    fi

    if command -v lazygit &>/dev/null; then
        local current
        current=$(lazygit --version | grep -oP 'version=\K[^,]+')
        if [[ "$current" == "$version" ]]; then
            log "Lazygit $current already installed, skipping."
            return
        fi
    fi

    local asset="lazygit_${version}_linux_${ARCH_GO}.tar.gz"
    local base="https://github.com/jesseduffield/lazygit/releases/download/v${version}"
    check_url_exists "$base/$asset" || return 1
    curl -fLo "$WORKDIR/lazygit.tar.gz" "$base/$asset" || { log_error "Failed to download Lazygit."; return 1; }

    if curl -fsSL -o "$WORKDIR/lazygit_checksums.txt" "$base/checksums.txt" 2>/dev/null; then
        local expected actual
        expected=$(grep "$asset" "$WORKDIR/lazygit_checksums.txt" | awk '{print $1}' | tr -d '\r')
        actual=$(sha256sum "$WORKDIR/lazygit.tar.gz" | awk '{print $1}')
        if [[ -n "$expected" && "$expected" != "$actual" ]]; then
            log_error "Checksum verification failed for Lazygit."
            return 1
        fi
    fi

    tar xf "$WORKDIR/lazygit.tar.gz" -C "$WORKDIR" lazygit || { log_error "Failed to extract Lazygit."; return 1; }
    as_root install "$WORKDIR/lazygit" -D -t /usr/local/bin/ || return 1
    log "Lazygit installed."
}

sys_bottom() {
    log "Installing bottom..."

    local response version
    response=$(curl -s "https://api.github.com/repos/ClementTsang/bottom/releases/latest")
    validate_github_api_response "$response" "Bottom" || return 1
    version=$(echo "$response" | jq -r '.tag_name')
    if [[ -z "$version" || "$version" == "null" ]]; then
        log_error "Could not retrieve latest Bottom version."
        return 1
    fi

    if command -v btm &>/dev/null && [[ "$(btm --version | awk '{print $2}')" == "$version" ]]; then
        log "Bottom $version already installed, skipping."
        return
    fi

    local base="https://github.com/ClementTsang/bottom/releases/download/${version}"
    case "$DISTRO_FAMILY" in
        debian)
            local url="$base/bottom_${version}-1_${ARCH_DEB}.deb"
            check_url_exists "$url" || return 1
            curl -fLo "$WORKDIR/bottom.deb" "$url" || return 1
            as_root dpkg -i "$WORKDIR/bottom.deb" || return 1
            ;;
        fedora|rhel)
            local rpm_url="$base/bottom-${version}-1.${ARCH_RPM}.rpm"
            if check_url_exists "$rpm_url" 2>/dev/null; then
                curl -fLo "$WORKDIR/bottom.rpm" "$rpm_url" || return 1
                as_root rpm -U "$WORKDIR/bottom.rpm" || return 1
            else
                log "RPM not found for this arch, falling back to tarball..."
                local tar_url="$base/bottom_${ARCH_TRIPLE}-unknown-linux-gnu.tar.gz"
                check_url_exists "$tar_url" || return 1
                curl -fLo "$WORKDIR/bottom.tar.gz" "$tar_url" || return 1
                tar xf "$WORKDIR/bottom.tar.gz" -C "$WORKDIR" btm || return 1
                as_root install "$WORKDIR/btm" -D -t /usr/local/bin/ || return 1
            fi
            ;;
    esac
    log "Bottom installed."
}

sys_lazyssh() {
    log "Installing lazyssh..."

    local response tag
    response=$(curl -fsSL https://api.github.com/repos/Adembc/lazyssh/releases/latest)
    validate_github_api_response "$response" "LazySSH" || return 1
    tag=$(echo "$response" | jq -r .tag_name)
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        log_error "Could not retrieve latest LazySSH version."
        return 1
    fi

    if command -v lazyssh &>/dev/null && [[ "$(lazyssh --version 2>/dev/null | awk '{print $NF}')" == "$tag" ]]; then
        log "LazySSH $tag already installed, skipping."
        return
    fi

    local archive="lazyssh_$(uname)_${ARCH_GO}.tar.gz"
    local base="https://github.com/Adembc/lazyssh/releases/download/${tag}"
    check_url_exists "$base/$archive" || return 1
    curl -fLo "$WORKDIR/$archive" "$base/$archive" || return 1

    if curl -fsSL -o "$WORKDIR/lazyssh_checksums.txt" "$base/checksums.txt" 2>/dev/null; then
        local expected actual
        expected=$(grep "$archive" "$WORKDIR/lazyssh_checksums.txt" | awk '{print $1}' | tr -d '\r')
        actual=$(sha256sum "$WORKDIR/$archive" | awk '{print $1}')
        if [[ -n "$expected" && "$expected" != "$actual" ]]; then
            log_error "Checksum verification failed for LazySSH."
            return 1
        fi
    fi

    tar -xzf "$WORKDIR/$archive" -C "$WORKDIR" lazyssh || return 1
    as_root install -m 0755 "$WORKDIR/lazyssh" /usr/local/bin/lazyssh || return 1
    log "LazySSH installed."
}

sys_nvim() {
    log "Installing Neovim..."

    local response version
    response=$(curl -s "https://api.github.com/repos/neovim/neovim/releases/latest")
    validate_github_api_response "$response" "Neovim" || return 1
    version=$(echo "$response" | jq -r '.tag_name')
    if [[ -z "$version" || "$version" == "null" ]]; then
        log_error "Could not retrieve latest Neovim version."
        return 1
    fi

    if command -v nvim &>/dev/null && [[ "$(nvim --version | head -1 | grep -oP 'v[\d.]+')" == "$version" ]]; then
        log "Neovim $version already installed, skipping."
        return
    fi

    local url="https://github.com/neovim/neovim/releases/download/${version}/nvim-linux-${ARCH_NVIM}.tar.gz"
    check_url_exists "$url" || return 1
    curl -fLo "$WORKDIR/nvim.tar.gz" "$url" || return 1

    local install_dir="/opt/nvim-${version}"
    as_root mkdir -p "$install_dir"
    as_root tar xf "$WORKDIR/nvim.tar.gz" -C "$install_dir" --strip-components=1 || return 1
    as_root ln -sf "${install_dir}/bin/nvim" /usr/local/bin/nvim
    log "Neovim installed."
}

# Node.js from the NodeSource repo — the same steps their setup_XX.x script
# does (key + repo + apt pin), without piping a remote script into root bash.
sys_nodejs() {
    log "Installing Node.js ${NODE_MAJOR}.x from NodeSource..."

    case "$DISTRO_FAMILY" in
        debian)
            curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
                | gpg --batch --yes --dearmor -o "$WORKDIR/nodesource.gpg" || return 1
            as_root install -D -m 0644 "$WORKDIR/nodesource.gpg" /usr/share/keyrings/nodesource.gpg

            as_root tee /etc/apt/sources.list.d/nodesource.sources >/dev/null <<EOF
Types: deb
URIs: https://deb.nodesource.com/node_${NODE_MAJOR}.x
Suites: nodistro
Components: main
Architectures: ${ARCH_DEB}
Signed-By: /usr/share/keyrings/nodesource.gpg
EOF
            # Prefer NodeSource's nodejs over the (older) distro package.
            as_root tee /etc/apt/preferences.d/nodejs >/dev/null <<EOF
Package: nodejs
Pin: origin deb.nodesource.com
Pin-Priority: 600
EOF
            as_root apt-get update || return 1
            ;;
        fedora|rhel)
            as_root tee /etc/yum.repos.d/nodesource-nodejs.repo >/dev/null <<EOF
[nodesource-nodejs]
name=Node.js Packages for Linux RPM based distros - ${ARCH_RPM}
baseurl=https://rpm.nodesource.com/pub_${NODE_MAJOR}.x/nodistro/nodejs/${ARCH_RPM}
priority=9
enabled=1
gpgcheck=1
gpgkey=https://rpm.nodesource.com/gpgkey/ns-operations-public.key
module_hotfixes=1
EOF
            ;;
    esac

    pkg_install nodejs || return 1
    log "Node.js $(node --version) installed."

    # tree-sitter-cli is required by the nvim config. Global npm packages land
    # in /usr/lib/node_modules → shared by all users. Newer npm skips install
    # scripts unless allowed; tree-sitter-cli's install.js fetches the binary.
    log "Installing tree-sitter-cli..."
    if as_root npm install -g --allow-scripts=tree-sitter-cli tree-sitter-cli \
        && tree-sitter --version &>/dev/null; then
        log "tree-sitter-cli installed."
    else
        log_error "tree-sitter-cli installation failed (or binary not working)."
        return 1
    fi
}

sys_uv() {
    log "Installing uv to /usr/local/bin..."
    curl -LsSf https://astral.sh/uv/install.sh -o "$WORKDIR/uv-install.sh" || return 1
    as_root env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh "$WORKDIR/uv-install.sh" || return 1
    command -v uv &>/dev/null || { log_error "uv not found after install."; return 1; }
    log "uv installed."
}

sys_oh_my_zsh() {
    log "Installing shared oh-my-zsh to $OMZ_DIR..."
    root_git_sync https://github.com/ohmyzsh/ohmyzsh.git "$OMZ_DIR" || return 1
    root_git_sync https://github.com/zsh-users/zsh-syntax-highlighting.git \
        "$OMZ_DIR/custom/plugins/zsh-syntax-highlighting" || return 1
    root_git_sync https://github.com/zsh-users/zsh-autosuggestions.git \
        "$OMZ_DIR/custom/plugins/zsh-autosuggestions" || return 1
    log "oh-my-zsh installed."
}

sys_tmux() {
    log "Installing shared gpakosz/.tmux to $TMUX_DIR..."
    root_git_sync https://github.com/gpakosz/.tmux.git "$TMUX_DIR" || return 1
    log "tmux config installed."
}

sys_shared_files() {
    log "Writing shared files to $SHARE_DIR..."
    as_root install -d -m 0755 "$SHARE_DIR"

    if curl -fsSL "$VIMRC_URL" -o "$WORKDIR/vimrc"; then
        as_root install -m 0644 "$WORKDIR/vimrc" "$SHARED_VIMRC"
    else
        log "Warning: could not download vimrc."
    fi

    # Shared zsh settings. Users source this from ~/.zshrc; edit it HERE and
    # rerun `profile.sh --system` — every user picks the change up at once.
    {
        echo "# Generated by profile.sh — do not edit, rerun 'profile.sh --system'."
        echo "export ZSH=$OMZ_DIR"
        cat <<'EOF'

# Can be overridden in ~/.zshrc BEFORE the line that sources this file.
: ${ZSH_THEME:=bira}
(( ${#plugins} )) || plugins=(z git zsh-syntax-highlighting jira zsh-autosuggestions aliases poetry battery terraform aws docker docker-compose kubectl)

# Shared install is updated by root (profile.sh --system), not per user.
zstyle ':omz:update' mode disabled

source "$ZSH/oh-my-zsh.sh"

typeset -U path
path=("$HOME/.local/bin" $path /usr/sbin)

alias sst='ss -nlptu'
alias sss='sudo -s'
alias less='less -F'
alias q='exit'
alias m='more'
alias grep='grep --colour=auto'
alias g='grep'
alias tt='tail -f'
alias getip='curl -fsSL eth0.me'
alias psc='ps xawf -eo pid,user,cgroup,args'
alias lll='ls -lha'
alias bench='curl -fsSL bench.sh | bash'
ipa() { curl -s "https://ifconfig.co/json?ip=$1" | jq 'del(.user_agent)' }

(( $+commands[duf] ))     && alias du='duf'
(( $+commands[lazygit] )) && alias lg='lazygit'
(( $+commands[lazyssh] )) && alias lss='lazyssh'

# bat is "batcat" on Debian, "bat" on Fedora/RHEL
if (( $+commands[batcat] )); then _bat=batcat
elif (( $+commands[bat] )); then _bat=bat
else _bat=
fi
if [[ -n $_bat ]]; then
    alias bb="$_bat -pp"
    [[ $_bat == batcat ]] && alias bat='batcat'
    export BAT_THEME='Monokai Extended Bright'
    export MANPAGER="sh -c 'col -bx | $_bat -l man -p'"
    export PAGER='less -F'
fi
unset _bat

if (( $+commands[uv] )); then
    eval "$(uv generate-shell-completion zsh)"
    eval "$(uvx --generate-shell-completion zsh)"
fi
EOF
    } > "$WORKDIR/common.zsh"
    as_root install -m 0644 "$WORKDIR/common.zsh" "$COMMON_ZSH"
    log "Shared files written."
}

SYSTEM_FAILED=()
run_system_step() {
    local name="$1"; shift
    if ! "$@"; then
        log_error "$name: failed, continuing."
        SYSTEM_FAILED+=("$name")
    fi
}

system_layer() {
    log "=== System layer ==="
    run_system_step "base packages" sys_base_packages
    run_system_step "lazygit"       sys_lazygit
    run_system_step "bottom"        sys_bottom
    run_system_step "lazyssh"       sys_lazyssh
    run_system_step "nvim"          sys_nvim
    run_system_step "nodejs"        sys_nodejs
    run_system_step "uv"            sys_uv
    run_system_step "oh-my-zsh"     sys_oh_my_zsh
    run_system_step "tmux"          sys_tmux
    run_system_step "shared files"  sys_shared_files

    # Marker only on full success — otherwise the next run retries the layer.
    if [[ ${#SYSTEM_FAILED[@]} -eq 0 ]]; then
        echo "installed $(date -Iseconds) by $USER" | as_root tee "$SYSTEM_MARKER" >/dev/null
        log "System layer done."
    else
        log_error "System layer incomplete (${SYSTEM_FAILED[*]}); it will be retried on the next run."
    fi
}

# =============================================================================
# === USER LAYER ==============================================================
# =============================================================================

user_zshrc() {
    local line="source $COMMON_ZSH"
    if [[ -f ~/.zshrc ]] && grep -qxF "$line" ~/.zshrc; then
        log "~/.zshrc already sources $COMMON_ZSH, skipping."
        return
    fi
    backup_config ~/.zshrc
    cat > ~/.zshrc <<EOF
# Shared settings (oh-my-zsh, aliases, PATH) live in $COMMON_ZSH
# Overrides for ZSH_THEME / plugins go ABOVE the source line.

$line

# Personal additions below
EOF
    log "~/.zshrc written (old one, if any, backed up)."
}

user_vimrc() {
    [[ -f "$SHARED_VIMRC" ]] || { log "Shared vimrc missing, skipping."; return; }
    [[ -L ~/.vimrc ]] || backup_config ~/.vimrc
    ln -sfn "$SHARED_VIMRC" ~/.vimrc
    log "~/.vimrc → $SHARED_VIMRC"
}

user_tmux() {
    # gpakosz/.tmux reads $HOME/.tmux.conf and $HOME/.tmux.conf.local, so the
    # main file can be a symlink into the shared clone.
    [[ -L ~/.tmux.conf ]] || backup_config ~/.tmux.conf
    ln -sfn "$TMUX_DIR/.tmux.conf" ~/.tmux.conf

    # .tmux.conf.local stays per user: gpakosz parses this file itself
    # (tmux_conf_* variables, @plugin lines), so it cannot just source a shared one.
    if [[ -f ~/.tmux.conf.local ]]; then
        if grep -q 'tmux-plugins/tmux-sessionist' ~/.tmux.conf.local; then
            log "~/.tmux.conf.local already configured, skipping."
            return
        fi
        backup_config ~/.tmux.conf.local
    else
        cp "$TMUX_DIR/.tmux.conf.local" ~/.tmux.conf.local
    fi

    cat >> ~/.tmux.conf.local <<'EOF'
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm*:Tc"
tmux_conf_copy_to_os_clipboard=true
set -g mouse off
bind -n WheelUpPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '#{pane_in_mode}' 'send-keys -M' 'copy-mode -e; send-keys -M'"
bind -n WheelDownPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '#{pane_in_mode}' 'send-keys -M' 'copy-mode -e; send-keys -M'"
set -g @plugin "tmux-plugins/tmux-sessionist"
set -g @plugin "tmux-plugins/tmux-resurrect"
set -g @plugin "tmux-plugins/tmux-continuum"
set -g @continuum-restore "on"
unbind C-b
set -g prefix C-a
bind C-a send-prefix
unbind %
bind | split-window -h
EOF
    log "tmux configured."
}

# Per user on purpose: lazy.nvim writes lazy-lock.json into the config dir,
# so a shared root-owned config would break for everyone else.
user_nvim_config() {
    mkdir -p ~/.config
    if [[ -d ~/.config/nvim/.git ]]; then
        git -C ~/.config/nvim pull --ff-only || { log_error "Failed to update Neovim config."; return 1; }
        log "Neovim config updated."
    else
        backup_config ~/.config/nvim
        rm -rf ~/.config/nvim
        git clone --depth 1 "$NVIM_CONFIG_REPO" ~/.config/nvim || { log_error "Failed to clone Neovim config."; return 1; }
        log "Neovim config cloned to ~/.config/nvim"
    fi
}

user_shell() {
    local zsh_path current
    zsh_path=$(command -v zsh) || { log_error "zsh not installed."; return 1; }
    current=$(getent passwd "$USER" | cut -d: -f7)
    if [[ "$current" == "$zsh_path" ]]; then
        log "Login shell is already zsh."
        return
    fi
    if [[ "$EUID" -eq 0 ]] || sudo -n true 2>/dev/null; then
        as_root chsh -s "$zsh_path" "$USER" || return 1
    else
        chsh -s "$zsh_path" || return 1   # asks for the user's password
    fi
    log "Login shell changed to $zsh_path."
}

# Things the old per-user version of the script left behind.
user_leftovers_hint() {
    local d found=()
    for d in ~/.oh-my-zsh ~/.tmux ~/.nvm; do
        [[ -e "$d" ]] && found+=("$d")
    done
    [[ ${#found[@]} -eq 0 ]] && return
    log "Not used anymore, can be removed after you check the new setup: ${found[*]}"
}

user_layer() {
    log "=== User layer for $USER ($HOME) ==="
    if [[ ! -f "$COMMON_ZSH" || ! -d "$OMZ_DIR" || ! -d "$TMUX_DIR" ]]; then
        log_error "System layer is missing. Run: $0 --system"
        return 1
    fi
    local step failed=()
    for step in user_zshrc user_vimrc user_tmux user_nvim_config user_shell; do
        "$step" || failed+=("$step")
    done
    user_leftovers_hint
    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "User layer: failed steps: ${failed[*]}"
        return 1
    fi
    log "User layer done. Start a new shell (or 'exec zsh') to use it."
}

# === CLI ======================================================================

MODE="auto"
DRY_RUN=0

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                cat <<EOF
Usage: $0 [--system | --user] [--dry-run]

  (no option)  System layer if not installed yet, then user layer.
  --system     (Re)install/update the system layer, then user layer.
  --user       User layer only.
  --dry-run    Show what would run, then exit.

Environment:
  NODE_MAJOR   NodeSource major version (default: $NODE_MAJOR)
EOF
                exit 0 ;;
            --system)  MODE="system" ;;
            --user)    MODE="user" ;;
            --dry-run) DRY_RUN=1 ;;
            *)
                echo "Unknown option: $1. Use --help for usage." >&2
                exit 1 ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"

    echo "profile.sh — Linux environment setup"
    echo "Log: $LOG_FILE"
    echo ""

    detect_distro

    local run_system=0
    case "$MODE" in
        system) run_system=1 ;;
        user)   run_system=0 ;;
        auto)   [[ -f "$SYSTEM_MARKER" ]] || run_system=1 ;;
    esac

    if [[ "$DRY_RUN" -eq 1 ]]; then
        if [[ "$run_system" -eq 1 ]]; then
            echo "Would run: system layer (packages, lazygit, bottom, lazyssh, nvim, Node ${NODE_MAJOR}.x, uv, oh-my-zsh, tmux, shared files)"
        else
            echo "System layer: skipped ($([[ -f $SYSTEM_MARKER ]] && cat "$SYSTEM_MARKER" || echo 'not installed, --user given'))"
        fi
        echo "Would run: user layer for $USER ($HOME)"
        exit 0
    fi

    start_log_capture

    if [[ "$run_system" -eq 1 ]]; then
        bootstrap_deps
        ensure_sudo
        system_layer
    else
        log "System layer already installed ($(cat "$SYSTEM_MARKER" 2>/dev/null || echo 'skipped by --user')), skipping."
    fi

    user_layer || true
    log "All done. Log saved to $LOG_FILE"
}

main "$@"
