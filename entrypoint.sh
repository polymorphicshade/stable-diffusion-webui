#!/usr/bin/env bash
#
# Container entrypoint for stable-diffusion-webui.
#
# Deliberately does NOT call webui.sh: that script is an installer/bootstrapper
# for bare-metal use. It creates its own venv, and when it can't find a
# `stable-diffusion-webui/` subdirectory next to itself it git-clones upstream
# AUTOMATIC1111 and runs that instead. Both of those fight with the image.
# Everything webui.sh would set up is already baked in at build time, so all
# that's left here is: sanity-check the mounts, set the library preloads, and
# run launch.py under the same restart loop the "Restart UI" button expects.

set -uo pipefail

APP_DIR=/app/stable-diffusion-webui
DATA_DIR=/data
CACHE_DIR=/app/.cache

die() { printf '\n[entrypoint] ERROR: %s\n\n' "$*" >&2; exit 1; }

# --- mounts ----------------------------------------------------------------
# Docker creates missing bind-mount sources as root:root, which this container
# (uid 1000) can't write to. Fail loudly with the fix instead of dying halfway
# through startup with a confusing traceback.
for dir in "$DATA_DIR" "$CACHE_DIR"; do
    mkdir -p "$dir" 2>/dev/null
    [[ -w "$dir" ]] || die "$dir is not writable by uid $(id -u).
       If it is a bind mount, fix ownership on the host:
           sudo install -d -o 1000 -g 1000 <host-path>
       then recreate the container."
done

# --data-dir tells the webui where user data lives; pre-create the tree so an
# empty volume looks like a fresh install rather than a broken one.
mkdir -p \
    "$DATA_DIR"/models/{Stable-diffusion,VAE,VAE-approx,Lora,ESRGAN,GFPGAN,Codeformer,hypernetworks,deepbooru,karlo} \
    "$DATA_DIR"/{extensions,embeddings,outputs,inputs,config_states} \
    "$APP_DIR"/tmp

# --- library preloads ------------------------------------------------------
# Resolved at runtime rather than hardcoded to /usr/local/cuda-12.1/... so that
# bumping CUDA_IMAGE doesn't silently leave LD_PRELOAD pointing at nothing.
if [[ -z "${LD_PRELOAD:-}" ]]; then
    preload=""
    for lib in /usr/local/cuda*/targets/x86_64-linux/lib/libcusparse.so.12 \
               /usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4; do
        [[ -e "$lib" ]] && preload="${preload:+$preload:}$lib"
    done
    [[ -n "$preload" ]] && export LD_PRELOAD="$preload"
fi

# --- launch ----------------------------------------------------------------
cd "$APP_DIR" || die "cannot cd to $APP_DIR"

# Signals to modules/restart.py that the "Restart UI" button is usable, and
# names the file it drops to ask for a restart.
export SD_WEBUI_RESTART=tmp/restart

child=0
forward() { [[ $child -ne 0 ]] && kill -TERM "$child" 2>/dev/null; }
trap forward TERM INT

# Mirrors the restart loop at the bottom of webui.sh: launch.py exits, and if it
# left tmp/restart behind we start it again. Backgrounding + wait (instead of
# exec) is what lets docker stop shut the UI down cleanly instead of waiting out
# the 10s SIGKILL timer.
while true; do
    python -u launch.py "$@" &
    child=$!
    wait "$child"
    status=$?
    child=0

    [[ -f tmp/restart ]] || exit "$status"

    printf '\n[entrypoint] restart requested, relaunching...\n\n'
done
