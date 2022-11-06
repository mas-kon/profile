#!/bin/bash

sudo yum -y update
sudo yum -y install wget vim mc net-tools dnsutils mlocate htop git ntpdate iotop tmux gpg bash-completion

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
echo "PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]$ '" >> .bashrc
