#!/bin/bash

# Setup 
sudo apt update && sudo apt install zsh bat curl vim mc net-tools dnsutils mlocate htop git chrony iotop tmux gpg parted bash-completion fonts-powerline ca-certificates apt-transport-https -y

git clone https://github.com/gpakosz/.tmux.git
ln -s -f .tmux/.tmux.conf
cp .tmux/.tmux.conf.local .

git clone https://github.com/VundleVim/Vundle.vim.git ~/.vim/bundle/Vundle.vim
wget https://raw.githubusercontent.com/mas-kon/profile/main/vimrc -O .vimrc
TERM=dumb vim +PluginInstall +qall < /dev/tty
sed -i 's/\"colorscheme/colorscheme/' .vimrc

sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

sed -i 's/robbyrussell/bira/' .zshrc
sed -i 's/\(git\)/git extract vscode battery zsh-autosuggestions terraform aws docker docker-compose/' .zshrc

echo "export PATH=$PATH:/usr/sbin/" >> .zshrc
echo "alias sst='ss -nlptu'" >> .zshrc
echo "alias sss='sudo -s'" >> .zshrc
echo "alias q='exit'" >> .zshrc
echo "alias m='more'" >> .zshrc
echo "alias grep='grep --colour=always'" >> .zshrc
echo "alias g='grep --colour=always'" >> .zshrc
echo "alias tt='tail -f'" >> .zshrc
echo "alias getip='wget -qO- eth0.me'" >> .zshrc
echo "alias lll='ls -lha --color=auto'" >> .zshrc
echo "alias bb='batcat -p --paging=never'" >> .zshrc
echo "alias bat='batcat'" >> .zshrc
echo "alias docker-compose='docker compose'" >> .zshrc
echo "export BAT_THEME='Monokai Extended Bright'" >> .zshrc
echo "export MANPAGER=\"sh -c 'col -bx | batcat -l man -p'\"" >> .zshrc

echo "source ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" >> .zshrc

sudo chsh -s /bin/zsh $USER



