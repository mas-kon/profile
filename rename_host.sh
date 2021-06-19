#!/usr/bin/env bash

if [ $# -ne 0 ]
then

  if [ $# -eq 2 ]
  then
    hostnamectl set-hostname $2
    sed -i "s/$1/$2/g" /etc/hosts
    sed -i "s/$1/$2/g" /etc/hostname
    sed -i "s/$1/$2/g" /etc/mailname
    sed -i "s/$1/$2/g" /etc/postfix/main.cf
  fi
  if [ $# -eq 1 ]
  then
    hostnamectl set-hostname $1
    sed -i "s/supertest/$1/g" /etc/hosts
    sed -i "s/supertest/$1/g" /etc/hostname
    sed -i "s/supertest/$1/g" /etc/mailname
    sed -i "s/supertest/$1/g" /etc/postfix/main.cf
  fi
else
    echo "No parameters found. "
fi
