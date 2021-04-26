#!/bin/bash

apt update
apt install mc sudo net-tools dnsutils mlocate htop git ntpdate iotop tmux vim

cd
git clone https://github.com/gpakosz/.tmux.git
ln -s -f .tmux/.tmux.conf
cp .tmux/.tmux.conf.local .

git clone https://github.com/VundleVim/Vundle.vim.git ~/.vim/bundle/Vundle.vim
wget https://raw.githubusercontent.com/mas-kon/profile/main/vimrc -O .vimrc
vim +PluginInstall +qall


echo "alias q='exit'" >> .bashrc
echo "alias m='more'" >> .bashrc
echo "alias g='grep'" >> .bashrc
echo "alias sss='sudo -s'" >> .bashrc
echo "alias tt='tail -f'" >> .bashrc
echo "alias ll='ls -lha --color=auto'" >> .bashrc
source .bashrc


