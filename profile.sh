#!/bin/bash

sudo apt update && sudo apt install vim mc net-tools dnsutils mlocate htop git ntpdate iotop tmux gpg parted bash-completion -y

cd
git clone https://github.com/gpakosz/.tmux.git
ln -s -f .tmux/.tmux.conf
cp .tmux/.tmux.conf.local .

git clone https://github.com/VundleVim/Vundle.vim.git ~/.vim/bundle/Vundle.vim
wget https://raw.githubusercontent.com/mas-kon/profile/main/vimrc -O .vimrc
vim +PluginInstall +qall
sed -i 's/\"colorscheme/colorscheme/' .vimrc

echo "export PATH=$PATH:/usr/sbin/" >> .bashrc
echo "alias sst='ss -nlptu'" >> .bashrc
echo "alias sss='sudo -s'" >> .bashrc
echo "alias q='exit'" >> .bashrc
echo "alias m='more'" >> .bashrc
echo "alias grep='grep --colour=always'" >> .bashrc
echo "alias g='grep --colour=always'" >> .bashrc
echo "alias tt='tail -f'" >> .bashrc
echo "alias getip='wget -qO- eth0.me'" >> .bashrc
echo "alias ll='ls -lha --color=auto'" >> .bashrc
echo "if [ "$(whoami)" != 'root' ]" >> .bashrc
echo " then" >> .bashrc
echo "    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]$ '" >> .bashrc
echo "else" >> .bashrc
echo "    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;31m\]\u@\h\[\033[00m\]:\[\033[01;35m\]\w\[\033[00m\]# '" >> .bashrc
echo "fi" >> .bashrc
source .bashrc
