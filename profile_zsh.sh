#!/bin/bash
set -e

cd ~ || { echo "Home catalog not found."; exit 1; }

# Enable sudo without password
disable_sudo_password() {
    if [[ $(id -nG "$USER" | grep -qw "sudo") ]]; then
        echo "${USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/${USER}
        fi
}


# Enable sudo without password
add_sudoers_entry() {
    if [[ ! -f /etc/sudoers.d/${USER} || "$UID" -ne 0 || ! $(id -nG "$USER" | grep -qw "sudo") || ! $(id -nG "$USER" | grep -qw "adm") ]]; then
        export C_USER=${USER}
        su -c 'echo "${C_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${C_USER}'
    fi
    sudo systemctl restart systemd-timesyncd
}


# Install package
min_install() {
    sudo apt update && sudo apt install -y tree mc bat zsh chrony curl vim htop git build-essential ca-certificates apt-transport-https sysstat ncdu python3-venv python3-pip python3-full jq
}


extended_install() {
    set +e

    sudo apt install -y fzf ripgrep gdu net-tools bash-completion duf dnsutils iotop tmux gpg parted fonts-powerline fd-find \
            libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
    sudo apt install -y gping
    sudo apt install -y duf
    sudo apt install -y zsh-syntax-highlighting
    set -e
}


# Install neovim
install_neovim() {
    if [[ ! -L /usr/local/bin/nvim ]]; then
        curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
        sudo rm -rf /opt/nvim
        sudo tar -C /opt -xzf nvim-linux-x86_64.tar.gz
        sudo ln -s /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim
        rm nvim-linux-x86_64.tar.gz
    fi
}

# Install lazygit
install_lazygit() {
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | \grep -Po '"tag_name": *"v\K[^"]*')
    curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
    tar xf lazygit.tar.gz lazygit
    sudo install lazygit -D -t /usr/local/bin/
    rm lazygit*
}

install_docker() {
    # Add Docker's official GPG key:
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources:
    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker $USER
    curl https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash
}

# Install tmux
install_tmux() {
    if [[ -d ~/.tmux ]]; then
        mv ~/.tmux ~/.tmux.bak
        git clone --single-branch https://github.com/gpakosz/.tmux.git
        ln -s -f .tmux/.tmux.conf
        cp .tmux/.tmux.conf.local .
        {
            echo 'set -g set-titles off'
	    echo 'set -g set-titles-string ""'
            echo 'set -g default-terminal "screen-256color"' 
            echo 'set -ga terminal-overrides ",xterm*:smcup@:rmcup@"'
            echo 'tmux_conf_copy_to_os_clipboard=true'
            echo 'set -g mouse on'
            echo 'set -g @plugin "tmux-plugins/tmux-sessionist"'
            echo 'set -g @plugin "tmux-plugins/tmux-resurrect"'
            echo 'set -g @plugin "tmux-plugins/tmux-continuum"'
            echo 'set -g @continuum-restore "on"'
            echo 'unbind %'
            echo 'bind | split-window -h'
        } >> .tmux.conf.local
    fi
}

#Install bottom https://github.com/ClementTsang/bottom
install_bottom() {
BTM_VERSION=$(curl -s "https://api.github.com/repos/ClementTsang/bottom/releases/latest" | grep  '"tag_name"' | cut -d '"' -f 4)
curl -Lo /tmp/bottom_0.10.2-1_amd64.deb "https://github.com/ClementTsang/bottom/releases/download/${BTM_VERSION}/bottom_${BTM_VERSION}-1_amd64.deb"
sudo dpkg -i /tmp/bottom_0.10.2-1_amd64.deb
rm /tmp/bottom_0.10.2-1_amd64.deb
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
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
    git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

    # Install .zshrc
    if [[ -f .zshrc ]]; then
        sed -i 's/robbyrussell/bira/' .zshrc
        sed -i 's/plugins=(.*)$/plugins=(z git zsh-syntax-highlighting jira zsh-autosuggestions aliases poetry battery zsh-autosuggestions terraform aws docker docker-compose kubectl tmux)/' .zshrc
    else
        echo ".zshrc not found." && exit 1
    fi
    echo "source ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" >> ~/.zshrc
    # Change shell
    sudo chsh -s "$(which zsh)" $USER
}


# Install nvm - Node Version Manager
install_nvm() {
    NVM_V=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep "tag_name" | cut -d '"' -f 4)
    if wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_V}/install.sh | bash; then
        echo "nvm installed."
        {
            echo 'export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"'
            echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
        } >> .zshrc

        echo "=============================  !!!!!!!!!!!!   =============================="
        echo "                                                                            "
        echo "Do not forget execute 'nvm install --lts' for node js after reload terminal."
        echo "                                                                            "
        echo "=============================  !!!!!!!!!!!!   =============================="
    else
        echo "Error install nvm." && exit 1
    fi
}

# Install UV
install_uv(){
    if curl -LsSf https://astral.sh/uv/install.sh | sh; then
        echo 'eval "$(uv generate-shell-completion zsh)"' >> ~/.zshrc
        echo 'eval "$(uvx --generate-shell-completion zsh)"' >> ~/.zshrc
        echo "UV installed."
    else
        echo "Error install UV." && exit 1
    fi
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
        echo "alias getip='wget -qO- eth0.me'"
        echo "alias psc='ps xawf -eo pid,user,cgroup,args'"
		echo "alias lll='ls -lha'"

        echo "alias bench='wget -qO- bench.sh | bash'"  
	echo "function ipa { curl -s https://ifconfig.co/json\?ip=$1 | jq 'del(.user_agent)' }"
        
    } >> .zshrc

    if command -v duf &> /dev/null;then
        {
            echo "alias du='duf'"
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

echo "All installed."


# Prompt user for installation type
echo "Select installation type:"
echo "1) Minimal"
echo "2) Extended"
read -rp "Enter choice [1-2]: " choice

case $choice in
    1)  
        disable_sudo_password
        add_sudoers_entry
        min_install
        install_neovim
        install_lazygit
        install_tmux
        install_oh_my_zsh
        add_aliases
        ;;
    2)
        read -rp "Do you want to install UV? (y/N): " install_uv_choice
		read -rp "Do you want to install docker? (y/N): " install_docker_choice
        read -rp "Do you want to disable_sudo_password? (y/N): " disable_sudo_password_choice
        read -rp "Do you want to add_sudoers_entry? (y/N): " add_sudoers_entry_choice
	
	if [[ "$disable_sudo_password_choice" =~ ^[Yy]$ ]]; then
            disable_sudo_password
        fi

 	if [[ "$add_sudoers_entry_choice" =~ ^[Yy]$ ]]; then
            add_sudoers_entry
        fi
	
        min_install
        extended_install
        install_neovim
        install_lazygit
	
        if [[ "$install_docker_choice" =~ ^[Yy]$ ]]; then
            install_docker
        fi
	
        install_tmux
        install_bottom
        install_oh_my_zsh
        install_nvm

        if [[ "$install_uv_choice" =~ ^[Yy]$ ]]; then
            install_uv
        fi	
	
        add_aliases
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac
