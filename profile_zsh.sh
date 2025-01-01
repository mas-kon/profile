#!/bin/bash
set -e

cd ~ || { echo "Не удалось перейти в домашний каталог."; exit 1; }

if [[ -f /etc/sudoers.d/${USER} || "$UID" -ne 0 ]]; then
    export C_USER=${USER}
	su -c 'echo "${C_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${C_USER}'
fi

# Установка пакетов
sudo apt update && sudo apt install -y fzf ripgrep xclip lazygit gdu zsh bat exa curl vim mc net-tools dnsutils htop git chrony iotop tmux gpg parted bash-completion fonts-powerline ca-certificates apt-transport-https sysstat ncdu

# Клонирование tmux конфигурации
if git clone https://github.com/gpakosz/.tmux.git; then
    ln -s -f .tmux/.tmux.conf
    cp .tmux/.tmux.conf.local .
else
    echo "Ошибка при клонировании репозитория .tmux."
fi

# Удаление oh-my-zsh, если он существует
if [[ -d ~/.oh-my-zsh ]]; then
    rm -Rf ~/.oh-my-zsh
    echo "Удален каталог ~/.oh-my-zsh."
else
    {echo "Каталог ~/.oh-my-zsh не найден, пропускаем удаление."; exit 1; }
fi

# Установка oh-my-zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# Клонирование плагинов zsh
mkdir -p ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

# Обновление .zshrc
if [[ -f .zshrc ]]; then
    sed -i 's/robbyrussell/bira/' .zshrc
    sed -i 's/$git$/git extract vscode battery zsh-autosuggestions terraform aws docker docker-compose kubectl/' .zshrc
else
    {echo ".zshrc не найден."; exit 1; }
fi

# Установка nvm
NVIM_V=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep "tag_name" | cut -d '"' -f 4)
if wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/${NVIM_V}/install.sh | bash; then
    echo "nvm установлен."
else
    {echo "Ошибка при установке nvm."; exit 1; }
fi

# Установка pyenv
if curl https://pyenv.run | bash; then
    echo "pyenv установлен."
else
    {echo "Ошибка при установке pyenv."; exit 1; }
fi

# Обновление .zshrc с алиасами
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

# Изменение оболочки пользователя
sudo chsh -s /bin/zsh ${USER}
