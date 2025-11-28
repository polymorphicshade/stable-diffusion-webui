FROM nvidia/cuda:12.9.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /app

RUN apt update -y && \
    apt install -y --no-install-recommends \
    software-properties-common \
    git \
    libgl1 \
    libgoogle-perftools4 \
    libtcmalloc-minimal4 \
    python3.10-venv \
    wget && \
    apt-add-repository --yes ppa:deadsnakes/ppa && \
    apt update -y && \
    apt install -y --no-install-recommends python3.10-venv

COPY . /app/stable-diffusion-webui
WORKDIR /app/stable-diffusion-webui

EXPOSE 7860

RUN echo 'venv_dir=/venv' > webui-user.sh

ENV install_dir=/
RUN ./webui.sh -f can_run_as_root --exit --skip-torch-cuda-test

ENV VIRTUAL_ENV=/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN . /venv/bin/activate && \
    pip install -U xformers --index-url https://download.pytorch.org/whl/cu121

VOLUME /root/.cache

CMD ["python3", "launch.py", "--listen"]