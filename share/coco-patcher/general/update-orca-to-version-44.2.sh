#!/bin/bash
pkexec apt-get install -y git debhelper-compat dh-python gnome-pkg-tools gettext libatk1.0-dev libatk-bridge2.0-dev libatspi2.0-dev libgstreamer1.0-dev pkg-config python3 python-gi-dev python3-brlapi python3-louis liblouis-dev python3-pyatspi python3-speechd yelp-tools
pkexec apt-get remove orca gnome-orca -y
cd /tmp
rm -rf /tmp/orca
git clone --depth 1 --branch ORCA_44_2 https://github.com/GNOME/orca.git

if [[ ! -d orca ]];
then 
    echo "Unable to clone latest orca. Press any key to Quit"
    read -n 1
    exit
fi

if [ $? -ne 0 ]; then
    echo "Unable to install build dependencies. Press any key to Quit"
    read -n 1
    exit
fi

cd /tmp/orca/
./autogen.sh
pkexec bash -c "cd /tmp/orca; make uninstall"
make
if [ $? -ne 0 ]; then
    echo "Unable to compile orca. Press any key to Quit"
    read -n 1
    exit
fi
pkexec apt-get remove -y orca orca-sops
if [ $? -ne 0 ]; then
    echo "Unable to remove orca. Press any key to Quit"
    read -n 1
    exit
fi
pkexec bash -c "cd /tmp/orca; make install"
echo "Press any key to Quit"
read -n 1
