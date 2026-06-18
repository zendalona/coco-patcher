#!/bin/bash

the_ppa=ppa.launchpad.net/nalin-x-linux/lios
if ! grep -q "^deb .*$the_ppa" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
    echo "Adding ppa.launchpad.net/nalin-x-linux/lios"
    pkexec add-apt-repository ppa:nalin-x-linux/lios -y
fi

pkexec apt-get install -y lios
echo "Press any key to Quit"
read -n 1
