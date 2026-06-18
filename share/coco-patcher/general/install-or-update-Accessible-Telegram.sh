#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "Re-running as root"
    exec sudo "$0" "$@"
fi

mkdir /usr/local/share/Accessible-Telegram-Desktop
cd /usr/local/share/Accessible-Telegram-Desktop

if [[ -f Accessible-Telegram-Desktop-1.0.appimage ]];
then 
    echo "Removing existing image!"
    rm Accessible-Telegram-Desktop-1.0.appimage
fi


wget https://master.dl.sourceforge.net/project/accessible-telegram-desktop/Accessible-Telegram-Desktop-1.0.appimage
if [ $? -ne 0 ];
then
    rm -f Accessible-Telegram-Desktop-1.0.appimage
    echo "Unable to download latest Accessible-Telegram-Desktop. Press any key to Quit"
    read -n 1
    exit
fi

chmod +x Accessible-Telegram-Desktop-1.0.appimage

echo "[Desktop Entry]
Version=1.0
Type=Application
Terminal=false
Icon=/usr/share/coco-patcher/icon.svg
Exec=/usr/local/share/Accessible-Telegram-Desktop/./Accessible-Telegram-Desktop-1.0.appimage
Categories=Network;
Name=Accessible-Telegram-Desktop" > /usr/local/share/applications/accessible-telegram-desktop.desktop

chmod +x /usr/local/share/applications/accessible-telegram-desktop.desktop

echo "Check Internet menu for Telegram-Desktop. Press any key to Quit"
read -n 1
