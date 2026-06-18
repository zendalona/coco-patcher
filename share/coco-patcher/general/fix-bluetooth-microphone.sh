#!/bin/sh
pactl unload-module module-bluetooth-discover
sleep 1 
pactl load-module module-bluetooth-discover
