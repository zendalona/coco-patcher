#!/bin/bash

the_ppa=ppa.launchpad.net/nalin-x-linux/maths-tutor
if ! grep -q "^deb .*$the_ppa" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
    echo "Adding ppa.launchpad.net/nalin-x-linux/maths-tutor"
    pkexec add-apt-repository ppa:nalin-x-linux/maths-tutor -y
fi

pkexec apt-get install -y maths-tutor

echo "Press any key to Quit"
read -n 1
