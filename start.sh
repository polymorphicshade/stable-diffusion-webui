#!/bin/bash

# require sudo
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
    exit 1
fi

# the container runs as uid/gid 1000; docker would otherwise create these bind
# mount sources as root:root and the webui could not write to them
install -d -o 1000 -g 1000 \
    ./.data \
    ./.data/models \
    ./.data/extensions \
    ./.data/embeddings \
    ./.data/outputs \
    ./.data/inputs

# stop the stack (in case there are new changes)
if docker compose ps --services --filter "status=running" | grep -q .; then
    docker compose down
fi

# NOTE: do not `docker builder prune` here. The build cache is what keeps the
# venv (torch/xformers, ~7GB) and repositories/ from being re-downloaded on
# every launch. To reclaim space deliberately, run `docker builder prune -f`
# by hand -- the next start will then take ~20 minutes instead of seconds.

# run docker (will also run at start-up)
docker compose pull --ignore-pull-failures || true
docker compose "$@" up -d --no-deps --build

# print the containers and their access points
./urls.sh
