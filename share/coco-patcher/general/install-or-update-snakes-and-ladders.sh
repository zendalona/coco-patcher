#!/bin/bash

the_ppa=ppa.launchpad.net/nalin-x-linux/snakes-and-ladders
if ! grep -q "^deb .*$the_ppa" /etc/apt/sources.list /etc/apt/sources.list.d/*; then
    echo "Adding ppa.launchpad.net/nalin-x-linux/snakes-and-ladders"
    pkexec add-apt-repository ppa:nalin-x-linux/snakes-and-ladders -y
fi

pkexec apt-get install -y snakes-and-ladders

echo "Press any key to Quit"
read -n 1
