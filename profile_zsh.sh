#!/usr/bin/env bash
set -e

cd ~ || { echo "Home catalog not found."; exit 1; }

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH_SUFFIX="x86_64"; ARCH_DEB="amd64" ;;
    aarch64) ARCH_SUFFIX="aarch64"; ARCH_DEB="arm64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Bootstrap: install sudo and curl if missing (bare Debian)
bootstrap_deps() {
    local missing=()
    command -v sudo &>/dev/null || missing+=(sudo)
    command -v curl &>/dev/null || missing+=(curl)

    if [[ ${#missing[@]} -eq 0 ]]; then
        return
    fi

    echo "Missing packages: ${missing[*]}. Installing..."
    if [[ "$EUID" -eq 0 ]]; then
        apt update && apt install -y "${missing[@]}"
    else
        su -c "apt update && apt install -y ${missing[*]}"
    fi

    # Ensure current user can use sudo
    if ! id -nG "$USER" | grep -qw "sudo"; then
        echo "Adding $USER to sudo group and creating sudoers entry..."
        if [[ "$EUID" -eq 0 ]]; then
            usermod -aG sudo "$USER"
            echo "${USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USER}"
        else
            su -c "/sbin/usermod -aG sudo $USER && echo '${USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${USER}"
        fi
    fi
}
bootstrap_deps

# Enable sudo without password
add_sudoers_entry() {
    if [[ ! -f /etc/sudoers.d/${USER} ]] && (id -nG "$USER" | grep -qw "sudo" || id -nG "$USER" | grep -qw "adm"); then
        echo "${USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/${USER} > /dev/null
    fi
}


# Install package
min_install() {
    sudo apt update && sudo apt install -y tree mc bat duf eza zsh chrony curl wget tmux vim htop git build-essential ca-certificates apt-transport-https sysstat ncdu python3-venv python3-pip python3-full jq ripgrep net-tools dnsutils iotop gpg parted fonts-powerline 
    curl -fsSL https://raw.githubusercontent.com/mas-kon/profile/main/vimrc -o .vimrc
    sudo apt install -y gping
    # sudo apt install -y zsh-syntax-highlighting
}

# Install lazygit
install_lazygit() {
    echo "Installing lazygit..."

    # Получаем последнюю версию Lazygit
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | /usr/bin/grep -Po '"tag_name": *"v\K[^"]*')
    if [[ -z "$LAZYGIT_VERSION" ]]; then
        echo "Error: Could not retrieve latest Lazygit version." >&2
        exit 1
    fi

    echo "Latest Lazygit version: $LAZYGIT_VERSION"

    # Скачиваем архив с Lazygit
    if ! curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${ARCH_SUFFIX}.tar.gz"; then
        echo "Error: Failed to download Lazygit archive." >&2
        exit 1
    fi

    # Распаковываем архив
    if ! tar xf lazygit.tar.gz lazygit; then
        echo "Error: Failed to extract Lazygit archive." >&2
        rm -f lazygit.tar.gz  # Удаляем загруженный архив при ошибке
        exit 1
    fi

    # Устанавливаем Lazygit
    if ! sudo install lazygit -D -t /usr/local/bin/; then
        echo "Error: Failed to install Lazygit." >&2
        rm -f lazygit.tar.gz lazygit  # Очищаем временные файлы при ошибке
        exit 1
    fi

    # Удаляем временные файлы
    rm -f lazygit.tar.gz lazygit

    echo "Lazygit installed."
}


# Install tmux
install_tmux() {
    if [[ -d ~/.tmux ]]; then
        mv ~/.tmux ~/.tmux.bak
    fi
    git clone --depth 1 --single-branch https://github.com/gpakosz/.tmux.git
    ln -s -f .tmux/.tmux.conf
    cp .tmux/.tmux.conf.local .
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
    } >> .tmux.conf.local
}

# Install bottom https://github.com/ClementTsang/bottom
install_bottom() {
    echo "Installing bottom..."

    # Получаем последнюю версию Bottom
    BTM_VERSION=$(curl -s "https://api.github.com/repos/ClementTsang/bottom/releases/latest" | grep '"tag_name"' | cut -d '"' -f 4)
    if [[ -z "$BTM_VERSION" ]]; then
        echo "Error: Could not retrieve latest Bottom version." >&2
        exit 1
    fi

    echo "Latest Bottom version: $BTM_VERSION"

    # Скачиваем deb-пакет
    if ! curl -Lo "/tmp/bottom_${BTM_VERSION}-1_${ARCH_DEB}.deb" "https://github.com/ClementTsang/bottom/releases/download/${BTM_VERSION}/bottom_${BTM_VERSION}-1_${ARCH_DEB}.deb"; then
        echo "Error: Failed to download Bottom package." >&2
        exit 1
    fi

    # Устанавливаем пакет
    if ! sudo dpkg -i "/tmp/bottom_${BTM_VERSION}-1_${ARCH_DEB}.deb"; then
        echo "Error: Failed to install Bottom package." >&2
        rm "/tmp/bottom_${BTM_VERSION}-1_${ARCH_DEB}.deb"  # Удаляем загруженный пакет при ошибке
        exit 1
    fi

    # Удаляем временный файл
    rm "/tmp/bottom_${BTM_VERSION}-1_${ARCH_DEB}.deb"

    echo "Bottom installed."
}

install_lazyssh() {
    echo "Installing lazyssh..."

    # Detect latest version
    LATEST_TAG=$(curl -fsSL https://api.github.com/repos/Adembc/lazyssh/releases/latest | jq -r .tag_name)
    if [[ -z "$LATEST_TAG" ]]; then
        echo "Error: Could not retrieve latest LazySSH version." >&2
        exit 1
    fi

    echo "Latest LazySSH version: $LATEST_TAG"

    # Download the correct binary for your system
    if ! curl -LJO "https://github.com/Adembc/lazyssh/releases/download/${LATEST_TAG}/lazyssh_$(uname)_$(uname -m).tar.gz"; then
        echo "Error: Failed to download LazySSH archive." >&2
        exit 1
    fi

    # Extract the binary
    if ! tar -xzf lazyssh_$(uname)_$(uname -m).tar.gz; then
        echo "Error: Failed to extract LazySSH archive." >&2
        rm -f lazyssh_$(uname)_$(uname -m).tar.gz  # Удаляем загруженный архив при ошибке
        exit 1
    fi

    # Check if the binary exists after extraction
    if [[ ! -f lazyssh ]]; then
        echo "Error: LazySSH binary not found after extraction." >&2
        rm -f lazyssh_$(uname)_$(uname -m).tar.gz  # Очищаем временные файлы
        exit 1
    fi

    # Move to /usr/local/bin or another directory in your PATH
    if ! sudo mv lazyssh /usr/local/bin/; then
        echo "Error: Failed to move LazySSH binary to /usr/local/bin/." >&2
        rm -f lazyssh_$(uname)_$(uname -m).tar.gz  # Очищаем временные файлы
        exit 1
    fi

    # Clean up the downloaded archive
    rm -f lazyssh_$(uname)_$(uname -m).tar.gz

    echo "LazySSH installed."
}

# Delete oh-my-zsh, if exits
install_oh_my_zsh() {
    # Delete old oh-my-zsh
    if [[ -d ~/.oh-my-zsh ]]; then
        rm -Rf ~/.oh-my-zsh
        echo "Removed ~/.oh-my-zsh."
    else
        echo "Directory ~/.oh-my-zsh not found, continue."
    fi

    # Install oh-my-zsh
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

    # Clone zsh
    mkdir -p ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins
    git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
    git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

    # Install .zshrc
    if [[ -f .zshrc ]]; then
        sed -i 's/robbyrussell/bira/' .zshrc
        sed -i 's/plugins=(.*)$/plugins=(z git zsh-syntax-highlighting jira zsh-autosuggestions aliases poetry battery zsh-autosuggestions terraform aws docker docker-compose kubectl)/' .zshrc
    else
        echo ".zshrc not found." && exit 1
    fi
    echo "source ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" >> ~/.zshrc
    # Change shell
    sudo chsh -s "$(which zsh)" $USER
}


# Install nvm - Node Version Manager
install_nvm() {
    echo "Installing nvm..."

    # Получаем последнюю версию NVM
    NVM_V=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep "tag_name" | cut -d '"' -f 4)
    if [[ -z "$NVM_V" ]]; then
        echo "Error: Could not retrieve latest NVM version." >&2
        exit 1
    fi

    echo "Latest NVM version: $NVM_V"

    # Загружаем и устанавливаем NVM
    if ! curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_V}/install.sh" | bash; then
        echo "Error: Failed to download or execute NVM installation script." >&2
        exit 1
    fi

    echo "nvm installed."

    # Добавляем экспорт переменной среды в .zshrc
    {
        echo 'export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"'
        echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
    } >> .zshrc

    # Экспортируем переменную и устанавливаем LTS версию Node.js
    export NVM_DIR="$HOME/.nvm"
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        \. "$NVM_DIR/nvm.sh"
        if ! nvm install --lts; then
            echo "Error: Failed to install Node.js LTS version." >&2
            exit 1
        fi
        if ! nvm use --lts; then
            echo "Error: Failed to use Node.js LTS version." >&2
            exit 1
        fi
    else
        echo "Error: NVM script not found at $NVM_DIR/nvm.sh" >&2
        exit 1
    fi
}

# Install UV
install_uv(){
    echo "Installing UV..."

    # Загружаем и устанавливаем UV
    if ! curl -LsSf https://astral.sh/uv/install.sh | sh; then
        echo "Error: Failed to download or execute UV installation script." >&2
        exit 1
    fi

    # Добавляем $HOME/.local/bin в PATH для текущей сессии
    export PATH="$HOME/.local/bin:$PATH"

    # Проверяем, что UV успешно установлен
    if ! command -v uv &> /dev/null; then
        echo "Error: UV was not installed correctly or is not in PATH." >&2
        exit 1
    fi

    # Добавляем $HOME/.local/bin в PATH в .zshrc, если ещё не добавлен
    if ! grep -q '$HOME/.local/bin' ~/.zshrc; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
    fi

    # Добавляем автодополнение в .zshrc
    {
        echo 'eval "$(uv generate-shell-completion zsh)"'
        echo 'eval "$(uvx --generate-shell-completion zsh)"'
    } >> ~/.zshrc

    echo "UV installed."
}

# Aliases in .zshrc
add_aliases() {
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
        echo "alias bench='curl -fsSL bench.sh | bash'"
        echo "function ipa { curl -s https://ifconfig.co/json\?ip=\$1 | jq 'del(.user_agent)' }"
    } >> .zshrc

    if command -v duf &> /dev/null;then
        {
            echo "alias du='duf'"
        } >> .zshrc
    fi

    if command -v eza &> /dev/null;then
        {
            echo "alias ls='eza --icons --group-directories-first'"
            echo "alias ll='eza -lhg --icons --group-directories-first'"
            echo "alias lll='eza -lahg --icons --group-directories-first'"
            echo "alias lt='eza --tree --icons --level=2' -a"
            echo "alias llg='eza -lhg --icons --git --group-directories-first'"
        } >> .zshrc
    else
        {
            echo "alias ll='ls -lh'" 
            echo "alias lll='ls -lha'"
        } >> .zshrc
    fi

    if command -v batcat &> /dev/null || command -v bat &> /dev/null; then
        {
            echo "alias bb='batcat -pp'"
            echo "alias bat='batcat'"
            echo "export BAT_THEME='Monokai Extended Bright'"
            echo "export MANPAGER=\"sh -c 'col -bx | batcat -l man -p'\""
            echo "export PAGER='less -F'"
        } >> .zshrc
    fi
}

read -rp "Do you want to add sudoers entry (NOPASSWD)? (y/N): " add_sudoers_entry_choice
read -rp "Do you want to install UV? (y/N): " install_uv_choice
read -rp "Do you want to install NVM? (y/N): " install_nvm_choice

if [[ "$add_sudoers_entry_choice" =~ ^[Yy]$ ]]; then
    add_sudoers_entry
fi


min_install
install_oh_my_zsh
if [[ "$install_uv_choice" =~ ^[Yy]$ ]]; then
    install_uv
fi
if [[ "$install_nvm_choice" =~ ^[Yy]$ ]]; then
    install_nvm
fi
install_lazygit
install_lazyssh
install_tmux
install_bottom
add_aliases

echo "All installed."
