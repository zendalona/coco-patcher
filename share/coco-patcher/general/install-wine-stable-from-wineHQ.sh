#!/bin/bash
pkexec dpkg --add-architecture i386
wget -nc https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/winehq-jammy.sources
pkexec mv ~/winehq-jammy.sources /etc/apt/sources.list.d/
pkexec mkdir -pm755 /etc/apt/keyrings
pkexec wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
pkexec apt update
pkexec apt-get install --install-recommends winehq-stable -y
echo "Press any key to Quit"
read -n 1
