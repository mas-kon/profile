#!/bin/bash

/usr/sbin/visudo

sudo -s
cd
echo "export PATH=$PATH:/usr/sbin/" >> .bashrc
echo "alias q='exit'" >> .bashrc
echo "alias m='more'" >> .bashrc
echo "alias g='grep'" >> .bashrc
echo "alias tf='tail -f'" >> .bashrc
echo "alias ll='ls -lha --color=auto'" >> .bashrc
source .bashrc
