#!/bin/bash

# require sudo
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
    exit 1
fi

./stop.sh && ./start.sh