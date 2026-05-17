#!/usr/bin/env bash
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$HOME/profile_install_${TIMESTAMP}.log"

# ─── Architecture detection ───────────────────────────────────────────────────

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH_SUFFIX="x86_64"; ARCH_DEB="amd64"; ARCH_RPM="x86_64"; ARCH_NVIM="x86_64" ;;
    aarch64) ARCH_SUFFIX="aarch64"; ARCH_DEB="arm64"; ARCH_RPM="aarch64"; ARCH_NVIM="arm64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ─── Distro abstraction ───────────────────────────────────────────────────────

DISTRO_FAMILY=""
PKG_UPDATE=""
PKG_INSTALL=""

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
            PKG_UPDATE="sudo dnf check-update || true"
            PKG_INSTALL="sudo dnf install -y" ;;
        rhel)
            PKG_UPDATE="sudo dnf check-update || true"
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
    $PKG_INSTALL "${packages[@]}"
}

# ─── Logging ──────────────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_error() {
    local msg="[$(date '+%H:%M:%S')] ERROR: $*"
    echo "$msg" | tee -a "$LOG_FILE" >&2
}

# ─── Utilities ────────────────────────────────────────────────────────────────

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

# ─── Bootstrap ────────────────────────────────────────────────────────────────

bootstrap_deps() {
    local missing=()
    command -v sudo &>/dev/null || missing+=(sudo)
    command -v curl &>/dev/null || missing+=(curl)

    if [[ ${#missing[@]} -eq 0 ]]; then
        return
    fi

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

    if ! id -nG "$USER" | grep -qw "sudo"; then
        log "Adding $USER to sudo group..."
        if [[ "$EUID" -eq 0 ]]; then
            usermod -aG sudo "$USER"
            echo "${USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USER}"
        else
            su -c "/sbin/usermod -aG sudo $USER && echo '${USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${USER}"
        fi
    fi
}

add_sudoers_entry() {
    if [[ ! -f /etc/sudoers.d/${USER} ]] && (id -nG "$USER" | grep -qw "sudo" || id -nG "$USER" | grep -qw "wheel" || id -nG "$USER" | grep -qw "adm"); then
        echo "${USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/${USER} > /dev/null
        log "Sudoers entry added for $USER."
    fi
}

# ─── Base packages ────────────────────────────────────────────────────────────

install_base_packages() {
    log "Installing base packages..."

    local canonical_packages=(
        tree mc bat zsh curl wget tmux vim htop git
        chrony sysstat ncdu jq ripgrep net-tools
        dns-tools iotop gpg parted fonts-powerline
        python3 dev-tools ca-certs
    )

    local resolved=()
    for pkg in "${canonical_packages[@]}"; do
        local resolved_name
        resolved_name=$(pkg_name "$pkg")
        [[ -n "$resolved_name" ]] && resolved+=($resolved_name)
    done

    $PKG_UPDATE
    install_packages "${resolved[@]}"

    # Dev tools group install (RPM only — apt uses build-essential above)
    if [[ "$DISTRO_FAMILY" == "fedora" || "$DISTRO_FAMILY" == "rhel" ]]; then
        log "Installing Development Tools group..."
        sudo dnf groupinstall -y "Development Tools"
        # Extra packages available on Fedora/RHEL but not in the canonical list
        sudo dnf install -y gping || log "Warning: gping not available, skipping."
    fi

    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
        sudo apt-get install -y gping || log "Warning: gping not available in apt, skipping."
    fi

    curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/vimrc -o ~/.vimrc
    log "Base packages installed."
}

# ─── Lazygit ──────────────────────────────────────────────────────────────────

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

    local url="https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${ARCH_SUFFIX}.tar.gz"
    check_url_exists "$url" || return 1

    if ! curl -Lo /tmp/lazygit.tar.gz "$url"; then
        log_error "Failed to download Lazygit archive."
        return 1
    fi

    local checksum_url="https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/checksums.txt"
    if curl -fsSL -o /tmp/lazygit_checksums.txt "$checksum_url" 2>/dev/null; then
        local expected_hash actual_hash
        expected_hash=$(grep "lazygit_${LAZYGIT_VERSION}_Linux_${ARCH_SUFFIX}.tar.gz" /tmp/lazygit_checksums.txt | awk '{print $1}')
        actual_hash=$(sha256sum /tmp/lazygit.tar.gz | awk '{print $1}')
        if [[ -n "$expected_hash" && "$expected_hash" == "$actual_hash" ]]; then
            log "Lazygit checksum verified."
        else
            log_error "Checksum verification failed for Lazygit."
            rm -f /tmp/lazygit.tar.gz /tmp/lazygit_checksums.txt
            return 1
        fi
        rm -f /tmp/lazygit_checksums.txt
    else
        log "Warning: Could not download checksums file, skipping verification."
    fi

    if ! tar xf /tmp/lazygit.tar.gz -C /tmp lazygit; then
        log_error "Failed to extract Lazygit archive."
        rm -f /tmp/lazygit.tar.gz
        return 1
    fi

    if ! sudo install /tmp/lazygit -D -t /usr/local/bin/; then
        log_error "Failed to install Lazygit."
        rm -f /tmp/lazygit.tar.gz /tmp/lazygit
        return 1
    fi

    rm -f /tmp/lazygit.tar.gz /tmp/lazygit
    log "Lazygit installed."
}

# ─── Bottom ───────────────────────────────────────────────────────────────────

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
            if ! curl -Lo "/tmp/bottom_${ARCH_DEB}.deb" "$url"; then
                log_error "Failed to download Bottom package."
                return 1
            fi
            if ! sudo dpkg -i "/tmp/bottom_${ARCH_DEB}.deb"; then
                log_error "Failed to install Bottom package."
                rm -f "/tmp/bottom_${ARCH_DEB}.deb"
                return 1
            fi
            rm -f "/tmp/bottom_${ARCH_DEB}.deb"
            ;;
        fedora|rhel)
            local rpm_url="https://github.com/ClementTsang/bottom/releases/download/${BTM_VERSION}/bottom-${BTM_VERSION}-1.${ARCH_RPM}.rpm"
            if check_url_exists "$rpm_url" 2>/dev/null; then
                if ! curl -Lo "/tmp/bottom.rpm" "$rpm_url"; then
                    log_error "Failed to download Bottom RPM."
                    return 1
                fi
                if ! sudo rpm -i "/tmp/bottom.rpm"; then
                    log_error "Failed to install Bottom RPM."
                    rm -f "/tmp/bottom.rpm"
                    return 1
                fi
                rm -f "/tmp/bottom.rpm"
            else
                log "RPM not found, falling back to tarball..."
                local tar_url="https://github.com/ClementTsang/bottom/releases/download/${BTM_VERSION}/bottom_${BTM_VERSION}_Linux_${ARCH_SUFFIX}.tar.gz"
                check_url_exists "$tar_url" || return 1
                curl -Lo /tmp/bottom.tar.gz "$tar_url"
                tar xf /tmp/bottom.tar.gz -C /tmp btm
                sudo install /tmp/btm -D -t /usr/local/bin/
                rm -f /tmp/bottom.tar.gz /tmp/btm
            fi
            ;;
    esac

    log "Bottom installed."
}

# ─── LazySSH ──────────────────────────────────────────────────────────────────

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

    local archive="lazyssh_$(uname)_$(uname -m).tar.gz"
    local url="https://github.com/Adembc/lazyssh/releases/download/${LATEST_TAG}/${archive}"
    check_url_exists "$url" || return 1

    if ! curl -LJo "/tmp/${archive}" "$url"; then
        log_error "Failed to download LazySSH archive."
        return 1
    fi

    if ! tar -xzf "/tmp/${archive}" -C /tmp lazyssh; then
        log_error "Failed to extract LazySSH archive."
        rm -f "/tmp/${archive}"
        return 1
    fi

    if [[ ! -f /tmp/lazyssh ]]; then
        log_error "LazySSH binary not found after extraction."
        rm -f "/tmp/${archive}"
        return 1
    fi

    if ! sudo mv /tmp/lazyssh /usr/local/bin/; then
        log_error "Failed to move LazySSH binary to /usr/local/bin/."
        rm -f "/tmp/${archive}"
        return 1
    fi

    rm -f "/tmp/${archive}"
    log "LazySSH installed."
}

# ─── Oh-My-Zsh ────────────────────────────────────────────────────────────────

install_oh_my_zsh() {
    log "Installing Oh-My-Zsh..."

    if [[ -d ~/.oh-my-zsh ]]; then
        rm -rf ~/.oh-my-zsh
        log "Removed ~/.oh-my-zsh."
    fi

    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

    local plugins_dir="${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins"
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
        backup_config ~/.zshrc
        sed -i 's/robbyrussell/bira/' ~/.zshrc
        sed -i 's/plugins=(.*)/plugins=(z git zsh-syntax-highlighting jira zsh-autosuggestions aliases poetry battery terraform aws docker docker-compose kubectl)/' ~/.zshrc
    else
        log_error ".zshrc not found."
        return 1
    fi

    sudo chsh -s "$(which zsh)" "$USER"
    log "Oh-My-Zsh installed."
}

# ─── Tmux ─────────────────────────────────────────────────────────────────────

install_tmux() {
    log "Installing tmux configuration..."

    if [[ -d ~/.tmux ]]; then
        backup_config ~/.tmux
        rm -rf ~/.tmux
    fi

    git clone --depth 1 --single-branch https://github.com/gpakosz/.tmux.git ~/.tmux
    ln -sf ~/.tmux/.tmux.conf ~/.tmux.conf
    cp ~/.tmux/.tmux.conf.local ~/.tmux.conf.local

    if grep -q 'tmux-plugins/tmux-sessionist' ~/.tmux.conf.local 2>/dev/null; then
        log "Tmux config already configured, skipping."
        return
    fi

    backup_config ~/.tmux.conf.local

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

# ─── Neovim ───────────────────────────────────────────────────────────────────

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

    if ! curl -Lo /tmp/nvim.tar.gz "$url"; then
        log_error "Failed to download Neovim archive."
        return 1
    fi

    local install_dir="/opt/nvim-${NVIM_VERSION}"
    sudo mkdir -p "$install_dir"

    if ! sudo tar xf /tmp/nvim.tar.gz -C "$install_dir" --strip-components=1; then
        log_error "Failed to extract Neovim archive."
        rm -f /tmp/nvim.tar.gz
        return 1
    fi

    sudo ln -sf "${install_dir}/bin/nvim" /usr/local/bin/nvim
    rm -f /tmp/nvim.tar.gz
    log "Neovim installed."
}

install_nvim_config() {
    log "Installing Neovim config..."

    mkdir -p ~/.config

    if [[ -d ~/.config/nvim/.git ]]; then
        git -C ~/.config/nvim pull --ff-only
        log "Neovim config updated."
    else
        backup_config ~/.config/nvim
        [[ -d ~/.config/nvim ]] && rm -rf ~/.config/nvim
        if ! git clone --depth 1 https://github.com/mas-kon/nvim ~/.config/nvim; then
            log_error "Failed to clone Neovim config."
            return 1
        fi
        log "Neovim config installed at ~/.config/nvim"
    fi
}

# ─── NVM ──────────────────────────────────────────────────────────────────────

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
    {
        echo 'export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"'
        echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
    } >> ~/.zshrc

    export NVM_DIR="$HOME/.nvm"
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        # shellcheck source=/dev/null
        \. "$NVM_DIR/nvm.sh"
        if ! nvm install --lts; then
            log_error "Failed to install Node.js LTS."
            return 1
        fi
        nvm use --lts
    else
        log_error "NVM script not found at $NVM_DIR/nvm.sh"
        return 1
    fi

    log "nvm installed."
}

# ─── UV ───────────────────────────────────────────────────────────────────────

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

    if ! grep -q '$HOME/.local/bin' ~/.zshrc; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
    fi

    {
        echo 'eval "$(uv generate-shell-completion zsh)"'
        echo 'eval "$(uvx --generate-shell-completion zsh)"'
    } >> ~/.zshrc

    log "UV installed."
}

# ─── Aliases ──────────────────────────────────────────────────────────────────

add_aliases() {
    if grep -q 'alias sst=' ~/.zshrc 2>/dev/null; then
        log "Aliases already added, skipping."
        return
    fi

    backup_config ~/.zshrc

    {
        echo "export PATH=\$PATH:/usr/sbin/:$HOME/.local/bin"
        echo "alias sst='ss -nlptu'"
        echo "alias sss='sudo -s'"
        echo "alias less='less -F'"
        echo "alias q='exit'"
        echo "alias m='more'"
        echo "alias grep='grep --colour=always'"
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

# ─── Interactive menu ─────────────────────────────────────────────────────────

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
        minimal)
            COMPONENT_STATE=(N Y N N N N N N N N N Y)
            return ;;
        full)
            COMPONENT_STATE=(Y Y Y Y Y Y Y Y Y Y Y Y)
            return ;;
        *)
            COMPONENT_STATE=("${COMPONENT_DEFAULTS[@]}") ;;
    esac

    while true; do
        echo ""
        echo "┌─────────────────────────────────────────────┐"
        echo "│          profile.sh — component selection   │"
        echo "├────┬──────────────────────────────────┬─────┤"
        for i in "${!COMPONENT_KEYS[@]}"; do
            local state="${COMPONENT_STATE[$i]}"
            local mark="[ ]"
            [[ "$state" == "Y" ]] && mark="[x]"
            printf "│ %s  │ %-32s │ %s │\n" "${COMPONENT_KEYS[$i]}" "${COMPONENT_NAMES[$i]}" "$mark"
        done
        echo "└────┴──────────────────────────────────┴─────┘"
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

# ─── CLI argument parsing ─────────────────────────────────────────────────────

MODE="interactive"
DRY_RUN=0

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                echo "Usage: $0 [--help] [--dry-run] [--minimal] [--full]"
                echo ""
                echo "  --minimal   Install base packages, oh-my-zsh, tmux, aliases only"
                echo "  --full      Install all components"
                echo "  --dry-run   Show what would be installed, then exit"
                exit 0 ;;
            --dry-run)
                DRY_RUN=1 ;;
            --minimal)
                MODE="minimal" ;;
            --full)
                MODE="full" ;;
            *)
                echo "Unknown option: $1. Use --help for usage." >&2
                exit 1 ;;
        esac
        shift
    done
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    echo "profile.sh — Linux environment setup"
    echo "Log: $LOG_FILE"
    echo ""

    detect_distro
    bootstrap_deps
    show_interactive_menu

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo ""
        echo "Dry run — components that would be installed:"
        for i in "${!COMPONENT_KEYS[@]}"; do
            [[ "${COMPONENT_STATE[$i]}" == "Y" ]] && echo "  - ${COMPONENT_NAMES[$i]}"
        done
        exit 0
    fi

    component_enabled "1" && add_sudoers_entry
    component_enabled "2" && install_base_packages
    component_enabled "3" && install_oh_my_zsh
    component_enabled "4" && install_tmux
    component_enabled "5" && install_lazygit
    component_enabled "6" && install_bottom
    component_enabled "7" && install_lazyssh
    component_enabled "8" && install_nvim
    component_enabled "9" && install_nvim_config
    component_enabled "A" && install_nvm
    component_enabled "B" && install_uv
    component_enabled "C" && add_aliases

    log "All done. Log saved to $LOG_FILE"
}

main "$@"
