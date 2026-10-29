#!/bin/bash

the_ppa="ppa.launchpad.net/zendalona-ac/accessible-coconut"
if ! grep -q "$the_ppa" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
    echo "Adding ppa:zendalona-ac/accessible-coconut"
    pkexec add-apt-repository ppa:zendalona-ac/accessible-coconut -y
fi

pkexec apt-get update
pkexec apt-get install -y maths-tutor

echo "Press any key to Quit"
read -n 1
