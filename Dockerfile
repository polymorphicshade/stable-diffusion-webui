# syntax=docker/dockerfile:1
#
# Stable Diffusion WebUI - CUDA image.
#
# Everything expensive (torch, python deps, the pinned `repositories/` clones) is
# baked into the image at build time, so container start is just "run launch.py".
# `prepare_environment()` in modules/launch_utils.py still runs at startup, but it
# finds every requirement already satisfied and exits in a couple of seconds.
#
# All user data (models, outputs, extensions, embeddings, config) lives under
# /data via --data-dir, so it survives image rebuilds.

ARG CUDA_IMAGE=nvidia/cuda:12.1.1-runtime-ubuntu22.04
FROM ${CUDA_IMAGE}

# Keep these in sync with modules/launch_utils.py:prepare_environment().
# If they ever drift, launch.py will fetch/checkout the correct commit at startup,
# so the image self-heals - it just costs a slower first boot.
ARG TORCH_VERSION=2.1.2
ARG TORCHVISION_VERSION=0.16.2
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu121
ARG XFORMERS_PACKAGE=xformers==0.0.23.post1
ARG CLIP_PACKAGE=https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip

ARG ASSETS_COMMIT_HASH=6f7db241d2f8ba7457bac5ca9753331f0c266917
ARG STABLE_DIFFUSION_COMMIT_HASH=cf1d67a6fd5ea1aa600c4df58e5b47da45f6bdbf
ARG STABLE_DIFFUSION_XL_COMMIT_HASH=45c443b316737a4ab6e40413d7794a7f5657c19f
ARG K_DIFFUSION_COMMIT_HASH=ab527a9a6d347f364e3d185ba6d714e22d80cb3c
ARG BLIP_COMMIT_HASH=48211a1594f1321b00f14c9f7a5b4813144b2fb9

# These ARG names deliberately match the env vars launch_utils.py honours, so the
# same override works at build time and at runtime.
#
# STABLE_DIFFUSION_REPO does NOT match launch_utils.py: Stability-AI/stablediffusion
# was pulled from GitHub and now 404s, which breaks every fresh install (upstream
# issue #17204). This is the maintainer's fork that upstream's dev branch moved to;
# it carries the identical commit STABLE_DIFFUSION_COMMIT_HASH pins.
ARG ASSETS_REPO=https://github.com/AUTOMATIC1111/stable-diffusion-webui-assets.git
ARG STABLE_DIFFUSION_REPO=https://github.com/w-e-w/stablediffusion.git
ARG STABLE_DIFFUSION_XL_REPO=https://github.com/Stability-AI/generative-models.git
ARG K_DIFFUSION_REPO=https://github.com/crowsonkb/k-diffusion.git
ARG BLIP_REPO=https://github.com/salesforce/BLIP.git

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore \
    GRADIO_ANALYTICS_ENABLED=False \
    SD_DATA_DIR=/data

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
# Ubuntu 22.04 already ships Python 3.10, which is what the WebUI wants.
# build-essential + python3.10-dev are kept so extensions with native bits can
# build their own wheels without a rebuild of this image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        libgl1 \
        libglib2.0-0 \
        libgomp1 \
        libgoogle-perftools4 \
        libtcmalloc-minimal4 \
        python3.10 \
        python3.10-dev \
        python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.10 /usr/local/bin/python \
    && ln -sf /usr/bin/python3.10 /usr/local/bin/python3 \
    && git config --global --add safe.directory '*'

# ---------------------------------------------------------------------------
# Packaging toolchain
# ---------------------------------------------------------------------------
# PIP_CONSTRAINT is honoured by every pip run in this container - image build,
# launch.py's run_pip(), and extension install.py scripts alike - so nothing can
# upgrade its way into a broken environment later. Lives in /etc so no volume
# mount can shadow it. See the file for what each bound is defending against.
COPY docker/constraints.txt /etc/pip-constraints.txt
ENV PIP_CONSTRAINT=/etc/pip-constraints.txt

RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    python -m pip install --upgrade pip setuptools wheel

WORKDIR /app

# ---------------------------------------------------------------------------
# Python dependencies - ordered cheapest-to-invalidate last
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    python -m pip install \
        "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" \
        --extra-index-url "${TORCH_INDEX_URL}"

# --no-deps mirrors what launch.py does; xformers would otherwise try to move torch.
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    python -m pip install --no-deps "${XFORMERS_PACKAGE}"

COPY requirements_versions.txt /app/requirements_versions.txt
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    python -m pip install -r /app/requirements_versions.txt

RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    python -m pip install "${CLIP_PACKAGE}"

# Fail the build here rather than at container start. pkg_resources is imported
# directly by modules/textual_inversion/autocrop.py and by pytorch_lightning.
RUN python -c "import pkg_resources, setuptools, torch, wheel; \
    print('pkg_resources OK | setuptools', setuptools.__version__, \
          '| wheel', wheel.__version__, '| torch', torch.__version__)"

# ---------------------------------------------------------------------------
# Pinned source repositories the WebUI expects in ./repositories
# ---------------------------------------------------------------------------
# Partial clones: full history is reachable (launch.py runs `git rev-parse HEAD`)
# but blobs are fetched lazily, keeping this layer small.
#
# GIT_TERMINAL_PROMPT=0 matters here: a deleted or private repo makes git ask for
# a username, which surfaces as the useless "could not read Username for
# 'https://github.com': No such device or address" instead of "repository not
# found". It stays set at runtime for the same reason.
ENV GIT_TERMINAL_PROMPT=0

RUN set -eux; \
    mkdir -p /app/repositories; \
    clone() { git clone --filter=blob:none --config core.filemode=false "$1" "$2"; git -C "$2" checkout -q "$3"; }; \
    clone "${ASSETS_REPO}"              /app/repositories/stable-diffusion-webui-assets "${ASSETS_COMMIT_HASH}"; \
    clone "${STABLE_DIFFUSION_REPO}"    /app/repositories/stable-diffusion-stability-ai "${STABLE_DIFFUSION_COMMIT_HASH}"; \
    clone "${STABLE_DIFFUSION_XL_REPO}" /app/repositories/generative-models "${STABLE_DIFFUSION_XL_COMMIT_HASH}"; \
    clone "${K_DIFFUSION_REPO}"         /app/repositories/k-diffusion "${K_DIFFUSION_COMMIT_HASH}"; \
    clone "${BLIP_REPO}"                /app/repositories/BLIP "${BLIP_COMMIT_HASH}"

# launch.py re-resolves these on every boot. Persist them so a wiped volume or a
# drifted commit hash can't send it back to the dead upstream URL.
ENV ASSETS_REPO=${ASSETS_REPO} \
    STABLE_DIFFUSION_REPO=${STABLE_DIFFUSION_REPO} \
    STABLE_DIFFUSION_XL_REPO=${STABLE_DIFFUSION_XL_REPO} \
    K_DIFFUSION_REPO=${K_DIFFUSION_REPO} \
    BLIP_REPO=${BLIP_REPO}

# ---------------------------------------------------------------------------
# Application code - last, so edits only rebuild this layer
# ---------------------------------------------------------------------------
COPY . /app

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 7860

# Needed when the base image isn't an nvidia/cuda one; harmless otherwise.
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["python", "launch.py", "--data-dir", "/data", "--listen", "--port", "7860"]
