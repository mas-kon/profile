## Profile

My default linux profile

```shell
wget -qO- https://raw.githubusercontent.com/mas-kon/profile/main/profile_zsh.sh > /tmp/install.sh && bash /tmp/install.sh
```


git clone https://github.com/VundleVim/Vundle.vim.git ~/.vim/bundle/Vundle.vim
wget https://raw.githubusercontent.com/mas-kon/profile/main/vimrc -O .vimrc
TERM=dumb vim +PluginInstall +qall < /dev/tty
sed -i 's/\"colorscheme/colorscheme/' .vimrc
