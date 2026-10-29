#!/bin/bash
cd /tmp
if [[ -f teamviewer_amd64.deb ]]; then 
    rm teamviewer_amd64.deb
fi

echo "Downloading TeamViewer..."
wget -O /tmp/teamviewer_amd64.deb https://download.teamviewer.com/download/linux/teamviewer_amd64.deb
if [ $? -ne 0 ]; then
    rm -f /tmp/teamviewer_amd64.deb
    echo "Unable to download latest TeamViewer. Press any key to Quit"
    read -n 1
    exit 1
fi

echo "Installing TeamViewer..."
pkexec apt-get install -y /tmp/teamviewer_amd64.deb

echo "Press any key to Quit"
read -n 1
