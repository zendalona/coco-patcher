#!/bin/bash
cd /tmp
if [[ -f teamviewer_amd64.deb ]];
then 
    rm teamviewer_amd64.deb
fi

wget https://download.teamviewer.com/download/linux/teamviewer_amd64.deb
if [ $? -ne 0 ];
then
    rm -f teamviewer_amd64.deb
    echo "Unable to download latest TeamViewer. Press any key to Quit"
    read -n 1
    exit
fi
pkexec gdebi /tmp/teamviewer_amd64.deb -n
echo "Press any key to Quit"
read -n 1
