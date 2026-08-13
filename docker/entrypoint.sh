#!/usr/bin/env bash
# Prepares the persistent /data volume, then hands off to launch.py.
set -euo pipefail

DATA_DIR="${SD_DATA_DIR:-/data}"
APP_DIR="${SD_APP_DIR:-/app}"

mkdir -p \
    "${DATA_DIR}/models/Stable-diffusion" \
    "${DATA_DIR}/models/VAE" \
    "${DATA_DIR}/models/Lora" \
    "${DATA_DIR}/embeddings" \
    "${DATA_DIR}/extensions" \
    "${DATA_DIR}/outputs"

# The repo ships a few small model assets (models/VAE-approx/model.pt,
# models/karlo/ViT-L-14_stats.th). --data-dir moves models_path off the image, so
# copy them across on first boot. -n never clobbers what the user put there.
cp -rn "${APP_DIR}/models/." "${DATA_DIR}/models/" 2>/dev/null || true
cp -rn "${APP_DIR}/embeddings/." "${DATA_DIR}/embeddings/" 2>/dev/null || true

# Same allocator swap webui.sh does - noticeably lower RAM growth over a long
# session. Set NO_TCMALLOC=1 to skip it.
if [[ -z "${NO_TCMALLOC:-}" && -z "${LD_PRELOAD:-}" ]]; then
    for candidate in \
        /usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4 \
        /usr/lib/x86_64-linux-gnu/libtcmalloc.so.4; do
        if [[ -e "${candidate}" ]]; then
            export LD_PRELOAD="${candidate}"
            echo "Using TCMalloc: ${candidate}"
            break
        fi
    done
fi

exec "$@"
