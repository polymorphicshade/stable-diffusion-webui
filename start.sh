#!/bin/bash

# require sudo
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
    exit 1
fi

# stop the stack (in case there are new changes)
if docker compose ps --services --filter "status=running" | grep -q .; then
    docker compose down
fi

# clear build cache (so we don't continue to pile on a mess as updates are built)
docker builder prune -f

# run docker (will also run at start-up)
docker compose pull
docker compose "$@" up -d --no-deps --build

# print the containers and their access points
./urls.sh