#!/bin/bash
cd /tmp
rm -f /tmp/google-chrome-stable_current_amd64.deb

echo "Downloading Google Chrome..."
wget -O /tmp/google-chrome-stable_current_amd64.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
if [ $? -ne 0 ]; then
    rm -f /tmp/google-chrome-stable_current_amd64.deb
    echo "Unable to download Google Chrome. Press any key to Quit"
    read -n 1
    exit 1
fi

echo "Installing Google Chrome..."
pkexec apt-get update
pkexec apt-get install -y /tmp/google-chrome-stable_current_amd64.deb
rm -f /tmp/google-chrome-stable_current_amd64.deb

echo "Google Chrome installation complete. Press any key to Quit"
read -n 1
