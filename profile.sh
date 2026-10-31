#!/usr/bin/env bash
set -euo pipefail

# === Constants ================================================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$HOME/profile_install_${TIMESTAMP}.log"

# $USER may be unset in containers; guard against `set -u`.
USER="${USER:-$(id -un 2>/dev/null || true)}"

# Private scratch dir for downloads/extracts instead of fixed paths in /tmp
# (no collisions between runs/users, cleaned up on exit).
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/profile-install.XXXXXX")
cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# === Architecture detection ===================================================

ARCH=$(uname -m)
case "$ARCH" in
    # ARCH_DEB/RPM/NVIM: .deb/.rpm/tarball names per vendor.
    # ARCH_GO: goreleaser-style arch (lazygit/lazyssh use x86_64|arm64 with a
    #          lowercase "linux" for lazygit and "Linux" for lazyssh).
    # ARCH_TRIPLE: rust target-triple prefix (bottom tarballs like
    #          bottom_aarch64-unknown-linux-gnu.tar.gz).
    x86_64)  ARCH_DEB="amd64";  ARCH_RPM="x86_64";  ARCH_NVIM="x86_64"; ARCH_GO="x86_64";  ARCH_TRIPLE="x86_64" ;;
    aarch64) ARCH_DEB="arm64";  ARCH_RPM="aarch64"; ARCH_NVIM="arm64";  ARCH_GO="arm64";   ARCH_TRIPLE="aarch64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# === Distro abstraction =======================================================

DISTRO_FAMILY=""
PKG_UPDATE=""
PKG_INSTALL=""

# Run package-metadata update (PKG_UPDATE is set by detect_distro).
# `$PKG_UPDATE` is word-split ON PURPOSE (multi-word command string) — do not quote it.
# dnf check-update exits 100 when updates are available — not an error, so
# failures are handled here instead of embedding a broken `|| true` in the string.
update_pkg_cache() {
    # shellcheck disable=SC2086
    if ! $PKG_UPDATE; then
        log "Warning: package update failed (dnf's 100 just means updates available), continuing."
    fi
}

detect_distro() {
    if [[ ! -f /etc/os-release ]]; then
        echo "Error: /etc/os-release not found. Cannot detect distribution." >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu|linuxmint|pop|kali|raspbian)
            DISTRO_FAMILY="debian" ;;
        fedora)
            DISTRO_FAMILY="fedora" ;;
        rhel|centos|rocky|almalinux|ol)
            DISTRO_FAMILY="rhel" ;;
        *)
            case "${ID_LIKE:-}" in
                *debian*|*ubuntu*) DISTRO_FAMILY="debian" ;;
                *fedora*|*rhel*)   DISTRO_FAMILY="rhel" ;;
                *)
                    log_error "Unsupported distribution: ${PRETTY_NAME:-$ID}"
                    exit 1 ;;
            esac ;;
    esac

    case "$DISTRO_FAMILY" in
        debian)
            PKG_UPDATE="sudo apt-get update"
            PKG_INSTALL="sudo apt-get install -y" ;;
        fedora)
            PKG_UPDATE="sudo dnf check-update"
            PKG_INSTALL="sudo dnf install -y" ;;
        rhel)
            PKG_UPDATE="sudo dnf check-update"
            PKG_INSTALL="sudo dnf install -y" ;;
    esac

    log "Detected distribution: ${PRETTY_NAME:-$ID} (family: $DISTRO_FAMILY)"
}

# Map canonical package name to distro-specific name(s).
# Returns empty string if the package should be skipped on this distro.
pkg_name() {
    local canonical="$1"
    case "$DISTRO_FAMILY" in
        debian)
            case "$canonical" in
                bat)            echo "bat" ;;
                python3)        echo "python3-full python3-venv python3-pip" ;;
                dns-tools)      echo "dnsutils" ;;
                dev-tools)      echo "build-essential" ;;
                fonts-powerline) echo "fonts-powerline" ;;
                ca-certs)       echo "ca-certificates apt-transport-https" ;;
                *)              echo "$canonical" ;;
            esac ;;
        fedora|rhel)
            case "$canonical" in
                bat)            echo "bat" ;;
                python3)        echo "python3" ;;
                dns-tools)      echo "bind-utils" ;;
                dev-tools)      echo "" ;;  # handled via groupinstall
                fonts-powerline) echo "powerline-fonts" ;;
                ca-certs)       echo "" ;;  # built-in
                *)              echo "$canonical" ;;
            esac ;;
    esac
}

install_packages() {
    local packages=("$@")
    [[ ${#packages[@]} -eq 0 ]] && return
    log "Installing packages: ${packages[*]}"
    # shellcheck disable=SC2086
    if $PKG_INSTALL "${packages[@]}"; then
        return
    fi
    # One unavailable package fails the whole batch — retry one by one so the
    # rest still lands (common on RHEL where EPEL coverage differs).
    log "Bulk install failed, retrying packages individually..."
    local failed=() pkg
    for pkg in "${packages[@]}"; do
        # NOTE: `$PKG_UPDATE`/`$PKG_INSTALL`/`$pkg` word-splitting is intentional
        # (multi-word strings like "python3-full python3-venv") — do not quote.
        # shellcheck disable=SC2086
        if ! $PKG_INSTALL $pkg; then
            failed+=("$pkg")
            log_error "Package not available: $pkg"
        fi
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "Failed to install packages: ${failed[*]}"
        return 1
    fi
}

# === Logging ==================================================================

log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_error() {
    local msg="[$(date '+%H:%M:%S')] ERROR: $*"
    echo "$msg" | tee -a "$LOG_FILE" >&2
}

# === Utilities ================================================================

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

# === Bootstrap ================================================================

bootstrap_deps() {
    local missing=()
    command -v sudo &>/dev/null || missing+=(sudo)
    command -v curl &>/dev/null || missing+=(curl)

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "Missing packages: ${missing[*]}. Installing..."
        if [[ "$EUID" -eq 0 ]]; then
            case "$DISTRO_FAMILY" in
                debian) apt-get update && apt-get install -y "${missing[@]}" ;;
                fedora|rhel) dnf install -y "${missing[@]}" ;;
            esac
        else
            case "$DISTRO_FAMILY" in
                debian) su -c "apt-get update && apt-get install -y ${missing[*]}" ;;
                fedora|rhel) su -c "dnf install -y ${missing[*]}" ;;
            esac
        fi
    fi

    # Tools every installer relies on (GitHub API parsing, git clones).
    # Without them the installers fail with a misleading "Invalid JSON response".
    local need=() tool
    for tool in jq git; do
        command -v "$tool" &>/dev/null || need+=("$tool")
    done
    if [[ ${#need[@]} -gt 0 ]]; then
        log "Installing required tools: ${need[*]}..."
        # Failures fall through to the explicit check below instead of tripping set -e.
        if [[ "$EUID" -eq 0 ]]; then
            case "$DISTRO_FAMILY" in
                debian) { apt-get update && apt-get install -y "${need[@]}"; } || true ;;
                fedora|rhel) dnf install -y "${need[@]}" || true ;;
            esac
        else
            case "$DISTRO_FAMILY" in
                debian) { sudo apt-get update && sudo apt-get install -y "${need[@]}"; } || true ;;
                fedora|rhel) sudo dnf install -y "${need[@]}" || true ;;
            esac
        fi
    fi

    if ! command -v jq &>/dev/null || ! command -v git &>/dev/null; then
        log_error "Required tools (jq/git) could not be installed; install them manually and rerun."
        return 1
    fi
}

# Opt-in only (menu component 1). Validates the entry with visudo before
# installing it, uses 0440 mode, and avoids "." filenames that sudo ignores.
add_sudoers_entry() {
    local fname="${USER//./_}"
    local file="/etc/sudoers.d/${fname}"
    local entry="${USER} ALL=(ALL) NOPASSWD:ALL"
    local tmp="$WORKDIR/sudoers-entry"

    if [[ -f "$file" ]]; then
        log "Sudoers entry already present for $USER, skipping."
        return 0
    fi
    if ! (id -nG "$USER" | grep -qw "sudo" || id -nG "$USER" | grep -qw "wheel" || id -nG "$USER" | grep -qw "adm"); then
        log "User $USER is not in a sudo/wheel group; sudoers entry would have no effect, skipping."
        return 0
    fi

    echo "$entry" > "$tmp"
    if ! sudo visudo -cf "$tmp"; then
        log_error "Sudoers entry failed validation, not installed."
        return 1
    fi
    if ! sudo install -m 0440 "$tmp" "$file"; then
        log_error "Failed to install sudoers entry."
        return 1
    fi
    log "Sudoers entry added for $USER (file: /etc/sudoers.d/${fname}, mode 0440)."
}

# === Base packages ============================================================

install_base_packages() {
    log "Installing base packages..."

    # Enable EPEL before resolving packages — many tools (zsh, bat, ripgrep, mc, ncdu) live there on RHEL
    if [[ "$DISTRO_FAMILY" == "fedora" || "$DISTRO_FAMILY" == "rhel" ]]; then
        log "Enabling EPEL repository..."
        sudo dnf install -y epel-release || log "Warning: epel-release not available (may already be enabled)."
        sudo dnf install -y epel-next-release 2>/dev/null || true
        update_pkg_cache
    fi

    local canonical_packages=(
        tree mc bat zsh curl wget tmux vim htop git
        chrony sysstat ncdu duf jq ripgrep net-tools
        dns-tools iotop gpg parted fonts-powerline
        python3 dev-tools ca-certs
    )

    local resolved=()
    for pkg in "${canonical_packages[@]}"; do
        local resolved_name
        resolved_name=$(pkg_name "$pkg")
        [[ -n "$resolved_name" ]] && resolved+=($resolved_name)
    done

    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        update_pkg_cache
    fi
    install_packages "${resolved[@]}"

    # Dev tools group install (RPM only — apt uses build-essential above)
    if [[ "$DISTRO_FAMILY" == "fedora" || "$DISTRO_FAMILY" == "rhel" ]]; then
        log "Installing Development Tools group..."
        sudo dnf groupinstall -y "Development Tools"
        sudo dnf install -y gping || log "Warning: gping not available, skipping."
    fi

    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        sudo apt-get install -y gping || log "Warning: gping not available in apt, skipping."
    fi

    backup_config ~/.vimrc
    if curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/vimrc -o ~/.vimrc; then
        log "Vimrc downloaded to ~/.vimrc."
    else
        log "Warning: could not download vimrc."
    fi
    log "Base packages installed."
}

# === Lazygit ==================================================================

install_lazygit() {
    log "Installing lazygit..."

    local LAZYGIT_RESPONSE
    LAZYGIT_RESPONSE=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest")
    validate_github_api_response "$LAZYGIT_RESPONSE" "Lazygit" || return 1

    local LAZYGIT_VERSION
    LAZYGIT_VERSION=$(echo "$LAZYGIT_RESPONSE" | grep -Po '"tag_name": *"v\K[^"]*')
    if [[ -z "$LAZYGIT_VERSION" ]]; then
        log_error "Could not retrieve latest Lazygit version."
        return 1
    fi
    log "Latest Lazygit version: $LAZYGIT_VERSION"

    if command -v lazygit &>/dev/null; then
        local current
        current=$(lazygit --version | grep -oP 'version=\K[^,]+')
        if [[ "$current" == "$LAZYGIT_VERSION" ]]; then
            log "Lazygit $current already installed, skipping."
            return
        fi
    fi

    # Asset naming is all-lowercase goreleaser style: lazygit_<ver>_linux_<arch>.tar.gz
    local asset="lazygit_${LAZYGIT_VERSION}_linux_${ARCH_GO}.tar.gz"
    local url="https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/${asset}"
    check_url_exists "$url" || return 1

    if ! curl -Lo "$WORKDIR/lazygit.tar.gz" "$url"; then
        log_error "Failed to download Lazygit archive."
        return 1
    fi

    local checksum_url="https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/checksums.txt"
    if curl -fsSL -o "$WORKDIR/lazygit_checksums.txt" "$checksum_url" 2>/dev/null; then
        local expected_hash actual_hash
        expected_hash=$(grep "$asset" "$WORKDIR/lazygit_checksums.txt" | awk '{print $1}' | tr -d '\r')
        actual_hash=$(sha256sum "$WORKDIR/lazygit.tar.gz" | awk '{print $1}')
        if [[ -z "$expected_hash" ]]; then
            log "Warning: Hash entry not found in checksums.txt, skipping verification."
        elif [[ "$expected_hash" == "$actual_hash" ]]; then
            log "Lazygit checksum verified."
        else
            log_error "Checksum verification failed for Lazygit (expected: $expected_hash, got: $actual_hash)."
            return 1
        fi
    else
        log "Warning: Could not download checksums file, skipping verification."
    fi

    if ! tar xf "$WORKDIR/lazygit.tar.gz" -C "$WORKDIR" lazygit; then
        log_error "Failed to extract Lazygit archive."
        return 1
    fi

    if ! sudo install "$WORKDIR/lazygit" -D -t /usr/local/bin/; then
        log_error "Failed to install Lazygit."
        return 1
    fi

    log "Lazygit installed."
}

# === Bottom ===================================================================

install_bottom() {
    log "Installing bottom..."

    local BTM_RESPONSE
    BTM_RESPONSE=$(curl -s "https://api.github.com/repos/ClementTsang/bottom/releases/latest")
    validate_github_api_response "$BTM_RESPONSE" "Bottom" || return 1

    local BTM_VERSION
    BTM_VERSION=$(echo "$BTM_RESPONSE" | jq -r '.tag_name')
    if [[ -z "$BTM_VERSION" || "$BTM_VERSION" == "null" ]]; then
        log_error "Could not retrieve latest Bottom version."
        return 1
    fi
    log "Latest Bottom version: $BTM_VERSION"

    if command -v btm &>/dev/null; then
        local current
        current=$(btm --version | awk '{print $2}')
        if [[ "$current" == "$BTM_VERSION" ]]; then
            log "Bottom $current already installed, skipping."
            return
        fi
    fi

    case "$DISTRO_FAMILY" in
        debian)
            local url="https://github.com/ClementTsang/bottom/releases/download/${BTM_VERSION}/bottom_${BTM_VERSION}-1_${ARCH_DEB}.deb"
            check_url_exists "$url" || return 1
            if ! curl -Lo "$WORKDIR/bottom.deb" "$url"; then
                log_error "Failed to download Bottom package."
                return 1
            fi
            if ! sudo dpkg -i "$WORKDIR/bottom.deb"; then
                log_error "Failed to install Bottom package."
                return 1
            fi
            ;;
        fedora|rhel)
            local rpm_url="https://github.com/ClementTsang/bottom/releases/download/${BTM_VERSION}/bottom-${BTM_VERSION}-1.${ARCH_RPM}.rpm"
            if check_url_exists "$rpm_url" 2>/dev/null; then
                if ! curl -Lo "$WORKDIR/bottom.rpm" "$rpm_url"; then
                    log_error "Failed to download Bottom RPM."
                    return 1
                fi
                # rpm -U installs fresh AND upgrades — rpm -i fails on upgrade.
                if ! sudo rpm -U "$WORKDIR/bottom.rpm"; then
                    log_error "Failed to install Bottom RPM."
                    return 1
                fi
            else
                # No RPM for this arch (e.g. aarch64) — tarball fallback.
                # Asset naming: bottom_<triple>-unknown-linux-gnu.tar.gz (no version in the name)
                log "RPM not found for this arch, falling back to tarball..."
                local tar_url="https://github.com/ClementTsang/bottom/releases/download/${BTM_VERSION}/bottom_${ARCH_TRIPLE}-unknown-linux-gnu.tar.gz"
                check_url_exists "$tar_url" || return 1
                if ! curl -Lo "$WORKDIR/bottom.tar.gz" "$tar_url"; then
                    log_error "Failed to download Bottom tarball."
                    return 1
                fi
                if ! tar xf "$WORKDIR/bottom.tar.gz" -C "$WORKDIR" btm; then
                    log_error "Failed to extract Bottom tarball."
                    return 1
                fi
                if ! sudo install "$WORKDIR/btm" -D -t /usr/local/bin/; then
                    log_error "Failed to install Bottom binary."
                    return 1
                fi
            fi
            ;;
    esac

    log "Bottom installed."
}

# === LazySSH ==================================================================

install_lazyssh() {
    log "Installing lazyssh..."

    local LAZYSSH_RESPONSE
    LAZYSSH_RESPONSE=$(curl -fsSL https://api.github.com/repos/Adembc/lazyssh/releases/latest)
    validate_github_api_response "$LAZYSSH_RESPONSE" "LazySSH" || return 1

    local LATEST_TAG
    LATEST_TAG=$(echo "$LAZYSSH_RESPONSE" | jq -r .tag_name)
    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
        log_error "Could not retrieve latest LazySSH version."
        return 1
    fi
    log "Latest LazySSH version: $LATEST_TAG"

    if command -v lazyssh &>/dev/null; then
        local current
        current=$(lazyssh --version 2>/dev/null | awk '{print $NF}')
        if [[ "$current" == "$LATEST_TAG" ]]; then
            log "LazySSH $current already installed, skipping."
            return
        fi
    fi

    # Asset naming: lazyssh_Linux_x86_64.tar.gz / lazyssh_Linux_arm64.tar.gz —
    # uname -m gives aarch64 on ARM, so use the normalised arch instead.
    local archive="lazyssh_$(uname)_${ARCH_GO}.tar.gz"
    local url="https://github.com/Adembc/lazyssh/releases/download/${LATEST_TAG}/${archive}"
    check_url_exists "$url" || return 1

    if ! curl -LJo "$WORKDIR/${archive}" "$url"; then
        log_error "Failed to download LazySSH archive."
        return 1
    fi

    local checksum_url="https://github.com/Adembc/lazyssh/releases/download/${LATEST_TAG}/checksums.txt"
    if curl -fsSL -o "$WORKDIR/lazyssh_checksums.txt" "$checksum_url" 2>/dev/null; then
        local expected_hash actual_hash
        expected_hash=$(grep "$archive" "$WORKDIR/lazyssh_checksums.txt" | awk '{print $1}' | tr -d '\r')
        actual_hash=$(sha256sum "$WORKDIR/${archive}" | awk '{print $1}')
        if [[ -z "$expected_hash" ]]; then
            log "Warning: Hash entry not found in checksums.txt, skipping verification."
        elif [[ "$expected_hash" == "$actual_hash" ]]; then
            log "LazySSH checksum verified."
        else
            log_error "Checksum verification failed for LazySSH (expected: $expected_hash, got: $actual_hash)."
            return 1
        fi
    else
        log "Warning: Could not download checksums file, skipping verification."
    fi

    if ! tar -xzf "$WORKDIR/${archive}" -C "$WORKDIR" lazyssh; then
        log_error "Failed to extract LazySSH archive."
        return 1
    fi

    if [[ ! -f "$WORKDIR/lazyssh" ]]; then
        log_error "LazySSH binary not found after extraction."
        return 1
    fi

    if ! sudo install -m 0755 "$WORKDIR/lazyssh" /usr/local/bin/lazyssh; then
        log_error "Failed to install LazySSH binary to /usr/local/bin/."
        return 1
    fi

    log "LazySSH installed."
}

# === Oh-My-Zsh ================================================================

install_oh_my_zsh() {
    log "Installing Oh-My-Zsh..."

    if ! command -v zsh &>/dev/null; then
        log_error "zsh is not installed. Cannot install Oh-My-Zsh. Install zsh first (check EPEL is enabled on RHEL/Rocky)."
        return 1
    fi

    # Back up .zshrc BEFORE anything can overwrite it (the installer replaces it
    # unless KEEP_ZSHRC is set, which is why the manual backup here matters).
    if [[ -f ~/.zshrc ]]; then
        backup_config ~/.zshrc
    fi

    # Download the installer first; only remove the existing install when the
    # source is reachable — a failed download must not destroy the old setup.
    if ! curl -fsSL -o "$WORKDIR/omz-install.sh" https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh; then
        log_error "Failed to download Oh-My-Zsh installer (network error). Old installation left intact."
        return 1
    fi

    if [[ -d ~/.oh-my-zsh ]]; then
        backup_config ~/.oh-my-zsh
        rm -rf ~/.oh-my-zsh
        log "Removed ~/.oh-my-zsh."
    fi

    # KEEP_ZSHRC only when the current .zshrc already sources oh-my-zsh;
    # otherwise let the installer write a fresh .zshrc (it keeps the old one
    # as .zshrc.pre-oh-my-zsh). With KEEP_ZSHRC a distro-skeleton .zshrc
    # would be kept but would never source oh-my-zsh.
    if [[ -f ~/.zshrc ]] && grep -q 'oh-my-zsh' ~/.zshrc; then
        KEEP_ZSHRC=yes sh "$WORKDIR/omz-install.sh" --unattended
    else
        sh "$WORKDIR/omz-install.sh" --unattended
    fi

    if [[ ! -d ~/.oh-my-zsh ]]; then
        log_error "Oh-My-Zsh installation failed."
        return 1
    fi

    local plugins_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"
    mkdir -p "$plugins_dir"

    if [[ ! -d "$plugins_dir/zsh-syntax-highlighting" ]]; then
        git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting.git "$plugins_dir/zsh-syntax-highlighting"
    else
        log "zsh-syntax-highlighting already installed, skipping."
    fi

    if [[ ! -d "$plugins_dir/zsh-autosuggestions" ]]; then
        git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions "$plugins_dir/zsh-autosuggestions"
    else
        log "zsh-autosuggestions already installed, skipping."
    fi

    if [[ -f ~/.zshrc ]]; then
        sed -i 's/robbyrussell/bira/' ~/.zshrc
        sed -i 's/plugins=(.*)/plugins=(z git zsh-syntax-highlighting jira zsh-autosuggestions aliases poetry battery terraform aws docker docker-compose kubectl)/' ~/.zshrc
    else
        log_error ".zshrc not found."
        return 1
    fi

    sudo chsh -s "$(command -v zsh)" "$USER"
    log "Oh-My-Zsh installed."
}

# === Tmux =====================================================================

install_tmux() {
    log "Installing tmux configuration..."

    # Clone first; a failed clone must not destroy the existing setup.
    if ! git clone --depth 1 --single-branch https://github.com/gpakosz/.tmux.git "$WORKDIR/.tmux"; then
        log_error "Failed to clone gpakosz/.tmux. Existing configuration left intact."
        return 1
    fi

    if [[ -d ~/.tmux ]]; then
        backup_config ~/.tmux
        rm -rf ~/.tmux
    fi
    mv "$WORKDIR/.tmux" ~/.tmux

    # A regular ~/.tmux.conf is the user's own file; the usual symlink is not.
    [[ -L ~/.tmux.conf ]] || backup_config ~/.tmux.conf
    ln -sf ~/.tmux/.tmux.conf ~/.tmux.conf

    # Back up the user's local config BEFORE anything overwrites it; a fresh
    # template is only used as the base when no local config exists yet.
    if [[ -f ~/.tmux.conf.local ]]; then
        backup_config ~/.tmux.conf.local
    else
        cp ~/.tmux/.tmux.conf.local ~/.tmux.conf.local
    fi

    if grep -q 'tmux-plugins/tmux-sessionist' ~/.tmux.conf.local 2>/dev/null; then
        log "Tmux config already configured, skipping."
        return
    fi

    {
        echo 'set -g default-terminal "tmux-256color"'
        echo 'set -ga terminal-overrides ",xterm*:Tc"'
        echo 'tmux_conf_copy_to_os_clipboard=true'
        echo 'set -g mouse off'
        echo 'bind -n WheelUpPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '\''#{pane_in_mode}'\'' '\''send-keys -M'\'' '\''copy-mode -e; send-keys -M'\''"'
        echo 'bind -n WheelDownPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '\''#{pane_in_mode}'\'' '\''send-keys -M'\'' '\''copy-mode -e; send-keys -M'\''"'
        echo 'set -g @plugin "tmux-plugins/tmux-sessionist"'
        echo 'set -g @plugin "tmux-plugins/tmux-resurrect"'
        echo 'set -g @plugin "tmux-plugins/tmux-continuum"'
        echo 'set -g @continuum-restore "on"'
        echo 'unbind C-b'
        echo 'set -g prefix C-a'
        echo 'bind C-a send-prefix'
        echo 'unbind %'
        echo 'bind | split-window -h'
    } >> ~/.tmux.conf.local

    log "Tmux configuration installed."
}

# === Neovim ===================================================================

install_nvim() {
    log "Installing Neovim..."

    local NVIM_RESPONSE
    NVIM_RESPONSE=$(curl -s "https://api.github.com/repos/neovim/neovim/releases/latest")
    validate_github_api_response "$NVIM_RESPONSE" "Neovim" || return 1

    local NVIM_VERSION
    NVIM_VERSION=$(echo "$NVIM_RESPONSE" | jq -r '.tag_name')
    if [[ -z "$NVIM_VERSION" || "$NVIM_VERSION" == "null" ]]; then
        log_error "Could not retrieve latest Neovim version."
        return 1
    fi
    log "Latest Neovim version: $NVIM_VERSION"

    if command -v nvim &>/dev/null; then
        local current
        current=$(nvim --version | head -1 | grep -oP 'v[\d.]+')
        if [[ "$current" == "$NVIM_VERSION" ]]; then
            log "Neovim $current already installed, skipping."
            return
        fi
    fi

    local url="https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-${ARCH_NVIM}.tar.gz"
    check_url_exists "$url" || return 1

    if ! curl -Lo "$WORKDIR/nvim.tar.gz" "$url"; then
        log_error "Failed to download Neovim archive."
        return 1
    fi

    local install_dir="/opt/nvim-${NVIM_VERSION}"
    sudo mkdir -p "$install_dir"

    if ! sudo tar xf "$WORKDIR/nvim.tar.gz" -C "$install_dir" --strip-components=1; then
        log_error "Failed to extract Neovim archive."
        return 1
    fi

    sudo ln -sf "${install_dir}/bin/nvim" /usr/local/bin/nvim
    log "Neovim installed."
}

install_nvim_config() {
    log "Installing Neovim config..."

    mkdir -p ~/.config

    if [[ -d ~/.config/nvim/.git ]]; then
        if ! git -C ~/.config/nvim pull --ff-only; then
            log_error "Failed to update Neovim config (pull failed)."
            return 1
        fi
        log "Neovim config updated."
    else
        backup_config ~/.config/nvim
        [[ -d ~/.config/nvim ]] && rm -rf ~/.config/nvim
        if ! git clone --depth 1 https://github.com/mas-kon/nvim ~/.config/nvim; then
            log_error "Failed to clone Neovim config."
            return 1
        fi
        log "Neovim config cloned to ~/.config/nvim"
    fi

    # tree-sitter-cli is required by the nvim config. Load nvm.sh so both npm
    # and node land on PATH — works in this run (after install_nvm) and for a
    # previously installed nvm.
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        set +u  # nvm.sh uses unbound variables internally
        # shellcheck source=/dev/null
        \. "$NVM_DIR/nvm.sh"
        nvm use --lts >/dev/null 2>&1 || true
        set -u
    fi

    if ! command -v npm &>/dev/null; then
        log "Warning: npm not found, skipping tree-sitter-cli. Run 'npm install -g tree-sitter-cli' after login."
        return 0
    fi

    log "Installing tree-sitter-cli via $(command -v npm)..."
    if npm install -g tree-sitter-cli; then
        log "tree-sitter-cli installed."
    else
        log_error "tree-sitter-cli installation failed."
    fi
}

# === NVM ======================================================================

install_nvm() {
    log "Installing nvm..."

    local NVM_RESPONSE
    NVM_RESPONSE=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest)
    validate_github_api_response "$NVM_RESPONSE" "NVM" || return 1

    local NVM_V
    NVM_V=$(echo "$NVM_RESPONSE" | jq -r '.tag_name')
    if [[ -z "$NVM_V" || "$NVM_V" == "null" ]]; then
        log_error "Could not retrieve latest NVM version."
        return 1
    fi
    log "Latest NVM version: $NVM_V"

    if ! curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_V}/install.sh" | bash; then
        log_error "Failed to execute NVM installation script."
        return 1
    fi

    backup_config ~/.zshrc
    if ! grep -q 'NVM_DIR' ~/.zshrc 2>/dev/null; then
        {
            echo 'export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"'
            echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
        } >> ~/.zshrc
    fi

    export NVM_DIR="$HOME/.nvm"
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        set +u  # nvm.sh uses unbound variables internally
        # shellcheck source=/dev/null
        \. "$NVM_DIR/nvm.sh"
        if ! nvm install --lts; then
            set -u
            log_error "Failed to install Node.js LTS."
            return 1
        fi
        nvm use --lts
        set -u
    else
        log_error "NVM script not found at $NVM_DIR/nvm.sh"
        return 1
    fi

    log "nvm installed."
}

# === UV =======================================================================

install_uv() {
    log "Installing UV..."

    if ! curl -LsSf https://astral.sh/uv/install.sh | sh; then
        log_error "Failed to execute UV installation script."
        return 1
    fi

    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v uv &>/dev/null; then
        log_error "UV was not installed correctly or is not in PATH."
        return 1
    fi

    backup_config ~/.zshrc

    # Matches both "$HOME/.local/bin" and an already-expanded absolute path.
    if ! grep -q '\.local/bin' ~/.zshrc; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
    fi

    if ! grep -q 'uv generate-shell-completion' ~/.zshrc; then
        {
            echo 'eval "$(uv generate-shell-completion zsh)"'
            echo 'eval "$(uvx --generate-shell-completion zsh)"'
        } >> ~/.zshrc
    fi

    log "UV installed."
}

# === Aliases ==================================================================

add_aliases() {
    if grep -q 'alias sst=' ~/.zshrc 2>/dev/null; then
        log "Aliases already added, skipping."
        return
    fi

    backup_config ~/.zshrc

    {
        echo 'export PATH="$PATH:/usr/sbin:$HOME/.local/bin"'
        echo "alias sst='ss -nlptu'"
        echo "alias sss='sudo -s'"
        echo "alias less='less -F'"
        echo "alias q='exit'"
        echo "alias m='more'"
        echo "alias grep='grep --colour=auto'"
        echo "alias g='grep'"
        echo "alias tt='tail -f'"
        echo "alias getip='curl -fsSL eth0.me'"
        echo "alias psc='ps xawf -eo pid,user,cgroup,args'"
        echo "alias lll='ls -lha'"
        echo "alias bench='curl -fsSL bench.sh | bash'"
        echo "function ipa { curl -s https://ifconfig.co/json\?ip=\$1 | jq 'del(.user_agent)' }"
    } >> ~/.zshrc

    if command -v duf &>/dev/null; then
        echo "alias du='duf'" >> ~/.zshrc
    fi

    if command -v lazygit &>/dev/null; then
        echo "alias lg='lazygit'" >> ~/.zshrc
    fi

    if command -v lazyssh &>/dev/null; then
        echo "alias lss='lazyssh'" >> ~/.zshrc
    fi

    # Detect actual bat binary name (batcat on Debian, bat on Fedora/RHEL)
    local BAT_BIN=""
    if command -v batcat &>/dev/null; then
        BAT_BIN="batcat"
    elif command -v bat &>/dev/null; then
        BAT_BIN="bat"
    fi

    if [[ -n "$BAT_BIN" ]]; then
        {
            echo "alias bb='${BAT_BIN} -pp'"
            echo "alias bat='${BAT_BIN}'"
            echo "export BAT_THEME='Monokai Extended Bright'"
            echo "export MANPAGER=\"sh -c 'col -bx | ${BAT_BIN} -l man -p'\""
            echo "export PAGER='less -F'"
        } >> ~/.zshrc
    fi

    log "Aliases added."
}

# === Interactive menu =========================================================

declare -a COMPONENT_KEYS=(1 2 3 4 5 6 7 8 9 A B C)
declare -a COMPONENT_NAMES=(
    "sudoers NOPASSWD"
    "base packages"
    "oh-my-zsh"
    "tmux (gpakosz)"
    "lazygit"
    "bottom"
    "lazyssh"
    "nvim binary"
    "nvim config (mas-kon/nvim)"
    "nvm + Node LTS"
    "uv (Python)"
    "aliases"
)
declare -a COMPONENT_DEFAULTS=(N Y Y Y Y Y Y Y Y Y Y Y)
declare -a COMPONENT_STATE=()

show_interactive_menu() {
    # Apply mode overrides before showing menu
    case "${MODE:-interactive}" in
        min)
            COMPONENT_STATE=(N Y Y N N N N N N N N Y)
            return ;;
        full)
            COMPONENT_STATE=(Y Y Y Y Y Y Y Y Y Y Y Y)
            return ;;
        *)
            COMPONENT_STATE=("${COMPONENT_DEFAULTS[@]}") ;;
    esac

    while true; do
        echo ""
        echo "┌=============================================┐"
        echo "│          profile.sh — component selection   │"
        echo "├====┬==================================┬=====┤"
        for i in "${!COMPONENT_KEYS[@]}"; do
            local state="${COMPONENT_STATE[$i]}"
            local mark="[ ]"
            [[ "$state" == "Y" ]] && mark="[x]"
            printf "│ %s  │ %-32s │ %s │\n" "${COMPONENT_KEYS[$i]}" "${COMPONENT_NAMES[$i]}" "$mark"
        done
        echo "└====┴==================================┴=====┘"
        echo ""
        printf "Toggle (1-9,A-C), ENTER to confirm, q to quit: "
        read -r input

        [[ -z "$input" ]] && break
        [[ "$input" == "q" ]] && echo "Aborted." && exit 0

        local key="${input^^}"
        local found=0
        for i in "${!COMPONENT_KEYS[@]}"; do
            if [[ "${COMPONENT_KEYS[$i]}" == "$key" ]]; then
                if [[ "${COMPONENT_STATE[$i]}" == "Y" ]]; then
                    COMPONENT_STATE[$i]="N"
                else
                    COMPONENT_STATE[$i]="Y"
                fi
                found=1
                break
            fi
        done
        [[ $found -eq 0 ]] && echo "Unknown key: $input"
    done
}

component_enabled() {
    local key="$1"
    for i in "${!COMPONENT_KEYS[@]}"; do
        if [[ "${COMPONENT_KEYS[$i]}" == "$key" ]]; then
            [[ "${COMPONENT_STATE[$i]}" == "Y" ]]
            return
        fi
    done
    return 1
}

# === CLI argument parsing =====================================================

MODE="interactive"
DRY_RUN=0

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                echo "Usage: $0 [--help] [--dry-run] [--min] [--full]"
                echo ""
                echo "  --min       Install base packages, oh-my-zsh, aliases only (no nvim/tools)"
                echo "  --full      Install all components"
                echo "  --dry-run   Show what would be installed, then exit"
                exit 0 ;;
            --dry-run)
                DRY_RUN=1 ;;
            --min)
                MODE="min" ;;
            --full)
                MODE="full" ;;
            *)
                echo "Unknown option: $1. Use --help for usage." >&2
                exit 1 ;;
        esac
        shift
    done
}

# === Main =====================================================================

main() {
    parse_args "$@"

    echo "profile.sh — Linux environment setup"
    echo "Log: $LOG_FILE"
    echo ""

    detect_distro
    show_interactive_menu

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo ""
        echo "Dry run — components that would be installed:"
        for i in "${!COMPONENT_KEYS[@]}"; do
            [[ "${COMPONENT_STATE[$i]}" == "Y" ]] && echo "  - ${COMPONENT_NAMES[$i]}"
        done
        exit 0
    fi

    # Dry run must run BEFORE anything can install packages (bootstrap_deps).
    bootstrap_deps

    # Make sure sudo works for the rest of the run. Never silently grant
    # passwordless sudo or shuffle groups — passwordless sudo is opt-in
    # (menu component 1) and group changes are out of scope for this script.
    if [[ "$EUID" -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        if ! sudo -v; then
            log_error "sudo is not available for user $USER. Run the script as root or grant sudo access, then rerun."
            exit 1
        fi
    fi

    if component_enabled "1"; then add_sudoers_entry    || log_error "sudoers: failed, continuing."; fi
    if component_enabled "2"; then install_base_packages || log_error "base packages: failed, continuing."; fi
    if component_enabled "3"; then install_oh_my_zsh    || log_error "oh-my-zsh: failed, continuing."; fi
    if component_enabled "4"; then install_tmux          || log_error "tmux: failed, continuing."; fi
    if component_enabled "5"; then install_lazygit       || log_error "lazygit: failed, continuing."; fi
    if component_enabled "6"; then install_bottom        || log_error "bottom: failed, continuing."; fi
    if component_enabled "7"; then install_lazyssh       || log_error "lazyssh: failed, continuing."; fi
    if component_enabled "8"; then install_nvim          || log_error "nvim: failed, continuing."; fi
    # aliases (C) set PATH before nvm/uv completions; nvim config (9) needs npm
    # from nvm, so it runs AFTER nvm (A).
    if component_enabled "C"; then add_aliases           || log_error "aliases: failed, continuing."; fi
    if component_enabled "A"; then install_nvm           || log_error "nvm: failed, continuing."; fi
    if component_enabled "9"; then install_nvim_config   || log_error "nvim config: failed, continuing."; fi
    if component_enabled "B"; then install_uv            || log_error "uv: failed, continuing."; fi

    log "All done. Log saved to $LOG_FILE"
}

main "$@"
