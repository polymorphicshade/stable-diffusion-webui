# syntax=docker/dockerfile:1

# =============================================================================
# Base image
#
# Ubuntu 22.04: keep it. It ships Python 3.10, which is what this webui targets
# (modules/launch_utils.py:check_python_version only accepts 3.7-3.11, and
# gradio 3.41 / pytorch_lightning 1.9 / numpy 1.26 do not work on the Python
# 3.12 that Ubuntu 24.04 ships). 22.04 is supported until April 2027.
#
# CUDA 12.1: matches the cu121 torch wheels pinned below. The torch wheels
# bundle their own CUDA runtime libs, so this image mainly has to be "not older
# than" what torch expects.
#
# To move the whole stack forward, override these together -- they are wired
# through to the runtime as well, so the baked venv and prepare_environment()
# always agree and nothing gets reinstalled on first start:
#
#   docker compose build \
#     --build-arg CUDA_IMAGE=nvidia/cuda:12.4.1-runtime-ubuntu22.04 \
#     --build-arg TORCH_COMMAND="pip install torch==2.6.0 torchvision==0.21.0 --extra-index-url https://download.pytorch.org/whl/cu124" \
#     --build-arg XFORMERS_PACKAGE=xformers==0.0.29.post3
#
# xformers is built against one exact torch version -- check
# https://github.com/facebookresearch/xformers/releases for the right pairing
# before bumping. RTX 50xx (Blackwell, sm_120) needs cu128 + torch 2.7+.
# =============================================================================
ARG CUDA_IMAGE=nvidia/cuda:12.1.1-runtime-ubuntu22.04


# =============================================================================
# Stage 1: OS packages and the unprivileged user. Changes ~never.
# =============================================================================
FROM ${CUDA_IMAGE} AS system

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        aria2 \
        bc \
        ca-certificates \
        curl \
        git \
        libgl1 \
        libglib2.0-0 \
        libgoogle-perftools4 \
        libsm6 \
        libtcmalloc-minimal4 \
        libxext6 \
        libxrender1 \
        python3 \
        python3-pip \
        python3-venv \
        wget \
        xdg-utils \
    && rm -rf /var/lib/apt/lists/*

ARG APP_UID=1000
ARG APP_GID=1000
RUN groupadd -g ${APP_GID} sdgroup \
 && useradd -m -s /bin/bash -u ${APP_UID} -g ${APP_GID} --home-dir /app sduser \
 && mkdir -p /app/stable-diffusion-webui /app/.cache /data \
 && ln -s /app /home/sduser \
 && chown -R sduser:sdgroup /app /data

USER sduser
WORKDIR /app

# Everything cacheable lives under /app/.cache, which is a volume at runtime.
# Without this, HuggingFace re-downloads the CLIP text encoder (~2GB) every
# time the container is recreated.
ENV HOME=/app \
    XDG_CACHE_HOME=/app/.cache \
    HF_HOME=/app/.cache/huggingface \
    TORCH_HOME=/app/.cache/torch \
    PIP_CACHE_DIR=/app/.cache/pip \
    MPLCONFIGDIR=/app/.cache/matplotlib \
    VIRTUAL_ENV=/app/venv \
    PATH=/app/venv/bin:/app/.local/bin:$PATH


# =============================================================================
# Stage 2: the Python environment.
#
# This layer is keyed only on requirements_versions.txt, so editing webui source
# no longer re-downloads ~7GB of torch. The venv lives at /app/venv, outside the
# source tree, so `COPY . stable-diffusion-webui` can never clobber it either.
# =============================================================================
FROM system AS deps

# ARGs do not cross stage boundaries; redeclared for the cache mount below.
ARG APP_UID=1000
ARG APP_GID=1000

ARG TORCH_INDEX_URL="https://download.pytorch.org/whl/cu121"
ARG TORCH_COMMAND="pip install torch==2.1.2 torchvision==0.16.2 --extra-index-url https://download.pytorch.org/whl/cu121"
ARG XFORMERS_PACKAGE="xformers==0.0.23.post1"
ARG CLIP_PACKAGE="https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip"
ARG OPENCLIP_PACKAGE="https://github.com/mlfoundations/open_clip/archive/bb6e834e9c70d9c27d0dc3ecedeebeaeb1ffad6b.zip"

# Re-exported so prepare_environment() resolves the *same* versions at runtime
# that were installed at build time. If these drift, is_installed()/
# requirements_met() fail and the webui reinstalls packages on every start.
ENV TORCH_INDEX_URL="${TORCH_INDEX_URL}" \
    TORCH_COMMAND="${TORCH_COMMAND}" \
    XFORMERS_PACKAGE="${XFORMERS_PACKAGE}" \
    CLIP_PACKAGE="${CLIP_PACKAGE}" \
    OPENCLIP_PACKAGE="${OPENCLIP_PACKAGE}"

RUN python3 -m venv "${VIRTUAL_ENV}"

COPY --chown=sduser:sdgroup requirements_versions.txt /app/stable-diffusion-webui/requirements_versions.txt

# The pip cache is a BuildKit cache mount: kept on the host between builds (so a
# torch bump or a rebuild is fast) but not baked into the image.
RUN --mount=type=cache,target=/app/.cache/pip,uid=${APP_UID},gid=${APP_GID} \
    python -m pip install --upgrade pip wheel \
 && python -m ${TORCH_COMMAND} \
 && python -m pip install -U -I --no-deps ${XFORMERS_PACKAGE} \
 && python -m pip install ${CLIP_PACKAGE} \
 && python -m pip install ${OPENCLIP_PACKAGE} \
 && python -m pip install -r /app/stable-diffusion-webui/requirements_versions.txt


# =============================================================================
# Stage 3: the application + the repositories/ checkouts.
# =============================================================================
FROM deps AS app

WORKDIR /app/stable-diffusion-webui

COPY --chown=sduser:sdgroup . /app/stable-diffusion-webui

# Runs prepare_environment() with everything already installed, so all this does
# is clone repositories/ (stable-diffusion, generative-models, k-diffusion,
# BLIP, assets) and run extension installers. Baking it here is what makes the
# first real start a no-network operation.
#
# NOTE: launch.py is invoked directly rather than through webui.sh. webui.sh
# treats its own directory as the *install root* and git-clones upstream
# AUTOMATIC1111 into a `stable-diffusion-webui/` subdirectory when it doesn't
# find one -- which is exactly what was happening here, so the container was
# running upstream's code out of a nested checkout instead of this fork, with
# its models dir sitting outside every mounted volume.
RUN python -u launch.py \
        --skip-torch-cuda-test \
        --skip-python-version-check \
        --no-download-sd-model \
        --xformers \
        --data-dir /data \
        --exit

COPY --chown=sduser:sdgroup --chmod=755 entrypoint.sh /app/entrypoint.sh

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=20m --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1:7860/ || exit 1

# --data-dir puts models, extensions, embeddings, outputs, config.json,
# ui-config.json, styles.csv and cache.json under a single mounted directory.
# Extra flags from `docker compose` / `docker run` are appended to these.
ENTRYPOINT ["/app/entrypoint.sh", \
            "--data-dir", "/data", \
            "--listen", \
            "--port", "7860", \
            "--xformers"]
