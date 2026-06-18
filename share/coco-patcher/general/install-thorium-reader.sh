#!/bin/bash
cd /tmp

echo "Fetching latest Thorium Reader release info..."

THORIUM_VERSION=$(curl -s https://api.github.com/repos/edrlab/thorium-reader/releases/latest | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
GITHUB_BASE="https://github.com/edrlab/thorium-reader/releases/download/v${THORIUM_VERSION}"

if [ -z "$THORIUM_VERSION" ]; then
    echo "Unable to find the latest Thorium version. Press any key to Quit"
    read -n 1
    exit 1
fi

FILE_NAME="EDRLab.ThoriumReader_${THORIUM_VERSION}_amd64.deb"
DOWNLOAD_URL="${GITHUB_BASE}/${FILE_NAME}"

if [[ ! -f "$FILE_NAME" ]]; then 
    echo "Downloading Thorium v${THORIUM_VERSION}..."
    wget "$DOWNLOAD_URL"
    
    if [ $? -ne 0 ]; then
        rm -f "$FILE_NAME"
        echo "Unable to download latest Thorium Reader. Press any key to Quit"
        read -n 1
        exit 1
    fi
else
    echo "Latest version ($FILE_NAME) is already downloaded."
fi

echo "Installing $FILE_NAME..."
pkexec apt install -y "/tmp/$FILE_NAME"

read -p "Do you want to open Thorium Reader now? (y/n): " OPEN_APP

if [[ "$OPEN_APP" =~ ^[Yy]$ ]]; then
    echo "Launching Thorium Reader..."
    
    setsid thorium >/dev/null 2>&1 &
fi

echo "Press any key to Quit"
read -n 1
