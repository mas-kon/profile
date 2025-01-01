#!/bin/bash
set -e

cd ~ || { echo "Home catalog not found."; exit 1; }

if [[ ! -f /etc/sudoers.d/${USER} || "$UID" -ne 0 ]]; then
    export C_USER=${USER}
    su -c 'echo "${C_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${C_USER}'
fi

# Install package
sudo apt update && sudo apt install -y fzf ripgrep xclip gdu zsh bat eza curl vim mc net-tools dnsutils htop git chrony iotop tmux gpg parted bash-completion fonts-powerline ca-certificates apt-transport-https sysstat ncdu

LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | \grep -Po '"tag_name": *"v\K[^"]*')
curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
tar xf lazygit.tar.gz lazygit
sudo install lazygit -D -t /usr/local/bin/
rm lazygit*

# Clone tmux configuration
if git clone https://github.com/gpakosz/.tmux.git; then
    ln -s -f .tmux/.tmux.conf
    cp .tmux/.tmux.conf.local .
fi

# Delete oh-my-zsh, if exits
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
    sed -i 's/$git$/git extract vscode battery zsh-autosuggestions terraform aws docker docker-compose kubectl/' .zshrc
else
    echo ".zshrc not found." && exit 1
fi

# Install nvm
NVIM_V=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep "tag_name" | cut -d '"' -f 4)
if wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/${NVIM_V}/install.sh | bash; then
    echo "nvm installed."
else
    echo "Error install nvm." && exit 1
fi

# Install pyenv
if curl https://pyenv.run | bash; then
    echo "pyenv installed."
else
    echo "Error install pyenv." && exit 1
fi

# Aliases in .zshrc
{
    echo "export PATH=\$PATH:/usr/sbin/"
    echo "alias sst='ss -nlptu'"
    echo "alias sss='sudo -s'"
    echo "alias less='less -F'"
    echo "alias q='exit'"
    echo "alias m='more'"
    echo "alias grep='grep --colour=always'"
    echo "alias g='grep --colour=always'"
    echo "alias tt='tail -f'"
    echo "alias getip='wget -qO- eth0.me'"
    echo "alias ls='exa'"
    echo "alias lll='ls -lha'"
    echo "alias lm='ls --long --all --sort=modified'"
    echo "alias lmm='ls -lbHigUmuSa --sort=modified --time-style=long-iso'"
    echo "alias bb='batcat -pp'"
    echo "alias bat='batcat'"
    echo "alias psc='ps xawf -eo pid,user,cgroup,args'"
    echo "alias bench='wget -qO- bench.sh | bash'"
    echo "export BAT_THEME='Monokai Extended Bright'"
    echo "export MANPAGER=\"sh -c 'col -bx | batcat -l man -p'\""
    echo "export PAGER='less -F'"
        echo "source ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
} >> .zshrc

# Change shell
sudo chsh -s /bin/zsh ${USER}

echo "All installed."
