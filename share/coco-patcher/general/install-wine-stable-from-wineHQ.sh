#!/bin/bash

# Detect current Ubuntu codename (e.g. resolute)
source /etc/os-release
CODENAME="${VERSION_CODENAME:-resolute}"

echo "Configuring WineHQ repository for Ubuntu $CODENAME..."

pkexec bash -c "
    dpkg --add-architecture i386
    mkdir -pm755 /etc/apt/keyrings
    wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
    wget -O /etc/apt/sources.list.d/winehq-${CODENAME}.sources https://dl.winehq.org/wine-builds/ubuntu/dists/${CODENAME}/winehq-${CODENAME}.sources
    apt-get update
    apt-get install --install-recommends -y winehq-stable
"

echo "Press any key to Quit"
read -n 1
