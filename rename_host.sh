#!/usr/bin/env bash

if [ -n "$1" ]

then
    hostnamectl set-hostname $1
    sed -i 's/TEMPLATE/$1/' /etc/hosts
    sed -i 's/TEMPLATE/$1/' /etc/hostsname
    sed -i 's/TEMPLATE/$1/' /etc/mailname
    sed -i 's/TEMPLATE/$1/' /etc/postfix/main.cf
else
    echo "No parameters found. "
fi
