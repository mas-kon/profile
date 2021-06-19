#!/usr/bin/env bash

if [ -n "$1" ]

then
    hostnamectl set-hostname $1
    sed -i 's/TEMPLATE/$1/g' /etc/hosts
    sed -i 's/TEMPLATE/$1/g' /etc/hostname
    sed -i 's/TEMPLATE/$1/g' /etc/mailname
    sed -i 's/TEMPLATE/$1/g' /etc/postfix/main.cf
else
    echo "No parameters found. "
fi
