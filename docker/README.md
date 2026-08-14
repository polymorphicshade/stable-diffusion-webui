# Running the WebUI in Docker

## Requirements

- Docker Desktop (WSL2 backend on Windows) or Docker Engine + Compose v2
- An NVIDIA GPU with a recent driver. On Windows, Docker Desktop's WSL2 backend
  exposes the GPU automatically; on Linux you need `nvidia-container-toolkit`.

## First run

```bash
docker compose build      # ~10-15 min, downloads ~6 GB
docker compose up -d
docker compose logs -f
```

Then open <http://localhost:7860>.

The image ships **no checkpoint**. Put a `.safetensors` into
`./data/models/Stable-diffusion/` and either restart the container or hit the
refresh button next to the model dropdown.

> The default args include `--no-download-sd-model` because the SD 1.5 repo the
> WebUI auto-downloads from was removed from HuggingFace. Drop that flag from
> `.env` if you point `HF_ENDPOINT` at a mirror that still has it.

## Day-to-day

```bash
docker compose stop       # shut down
docker compose start      # back up in seconds - nothing is reinstalled
docker compose restart
```

`docker compose down` is also safe: named volumes survive it. Only
`docker compose down -v` wipes them, which would force the pinned `repositories/`
clones and the HuggingFace cache to be fetched again.

## HTTPS

`docker compose up -d` starts an nginx container alongside the WebUI. On first
boot it generates a self-signed certificate into `./certs` and serves the UI at
<https://localhost:8443>. Nothing to configure.

Your browser will warn about the certificate — expected, it's self-signed. Accept
the exception once. To silence it permanently, import `certs/fullchain.pem` into
your OS trust store, or drop a CA-issued `fullchain.pem` + `privkey.pem` into
`./certs` and `docker compose restart nginx` — the entrypoint leaves existing
files alone.

If you reach the box by hostname or LAN IP rather than `localhost`, add it to
`TLS_SAN` in `.env` before first boot (browsers reject a cert whose SAN doesn't
match, even one you've accepted). To regenerate after changing it:

```bash
rm -rf certs && docker compose restart nginx
```

The WebUI's own port is now bound to `127.0.0.1`, so nginx is the only way in
from another machine. TLS stops at nginx; the hop to the WebUI is plain HTTP over
the internal compose network.

> HTTPS encrypts the connection — it does not add access control. Anything that
> can reach the port can drive the UI, and `--enable-insecure-extension-access`
> is on by default. Add `--gradio-auth user:pass` to `COMMANDLINE_ARGS` before
> exposing this beyond your own machine.

### Putting something else behind its own nginx

Each stack runs its own proxy on its own port; they share nothing but the host.
In the other project's compose file, reuse this one's `nginx` service block and
change three things:

1. `HTTPS_PORT` — pick a free port, e.g. `9443`
2. `NGINX_CONF` — point at a copy of `docker/nginx/nginx.conf`
3. `proxy_pass` in that copy — your service's compose name and port

The `container_name` and `image` also need to differ, since both are global to
the Docker daemon rather than scoped to the compose project.

## Where things live

| Path in container      | Host                | Contents |
| ---------------------- | ------------------- | -------- |
| `/data`                | `./data`            | models, outputs, extensions, embeddings, `config.json`, `ui-config.json`, `styles.csv` |
| `/etc/nginx/certs`     | `./certs`           | TLS certificate and private key |
| `/app/repositories`    | `sd-repositories`   | the five pinned upstream repos, baked into the image |
| `/app/config_states`   | `sd-config-states`  | extension config snapshots |
| `/root/.cache`         | `sd-cache`          | HuggingFace / CLIP / pip downloads |

`/data` is wired up through `--data-dir`, so an image rebuild never touches your
models, settings or outputs.

## Why start-up is fast

`launch.py` still runs `prepare_environment()` on every boot, but everything it
checks for is already in the image: torch, xformers, CLIP, every pin in
`requirements_versions.txt`, and the five `repositories/` clones at their exact
commits. It finds them all satisfied and falls through in a couple of seconds.

For the absolute minimum, add `--skip-prepare-environment` to `COMMANDLINE_ARGS`
in `.env`. Remove it again for one boot after installing an extension, so the
extension's `install.py` gets a chance to run.

## Configuration

Edit `.env` at the repo root — `WEBUI_PORT` for the host port, `COMMANDLINE_ARGS`
for anything you'd normally put in `webui-user.sh`. Common additions:

```
--gradio-auth user:pass    password-protect the UI
--medvram                  GPUs under ~8 GB VRAM
--lowvram                  GPUs under ~4 GB VRAM
--nowebui                  API only
```

## Rebuilding

Editing Python/JS in the repo requires `docker compose build` (only the final
`COPY . /app` layer is redone, so it takes seconds). To skip that loop entirely
while developing, uncomment the source bind-mounts in `docker-compose.yml`.

If you bump a dependency pin in `requirements_versions.txt`, or a repo commit
hash in `modules/launch_utils.py`, rebuild — the matching `ARG` defaults at the
top of the `Dockerfile` should be updated to match. If they drift, `launch.py`
fixes it at runtime instead, at the cost of a slow boot.

## Dependency pinning

`docker/constraints.txt` is wired up as `PIP_CONSTRAINT`, so it applies to every
pip invocation in the container — the image build, `launch.py`'s `run_pip()`, and
any extension's `install.py`. It holds upper bounds only; exact versions still
come from `requirements_versions.txt`.

| Bound | Defends against |
| --- | --- |
| `setuptools<81` | 81 deprecates and later versions remove `pkg_resources`, which `modules/textual_inversion/autocrop.py` and `pytorch_lightning` import directly |
| `pip<24.1` | 24.1 began hard-rejecting the loose metadata several of the old pinned packages ship |
| `wheel<0.45` | 0.45 deprecated `wheel.bdist_wheel`, which some legacy `setup.py` files import |

The build fails fast if this goes wrong — there's an `import pkg_resources` smoke
check in the `Dockerfile` after the last pip step, so you find out at build time
rather than at container start.

If some package's *build* backend genuinely needs a newer setuptools, override
the constraint for that one install rather than removing the file:
`PIP_CONSTRAINT= pip install thatpackage`.

## Troubleshooting

**`ModuleNotFoundError: No module named 'pkg_resources'`** — something upgraded
setuptools past 81, usually an extension's `install.py` running `pip install -U`.
The entrypoint detects this on boot and reinstalls the pinned version rather than
crash-looping, so a `docker compose restart` should clear it. If it keeps coming
back, an extension is forcing the upgrade with `--no-deps` or similar; check
`docker compose logs | grep -i setuptools`.

**`could not read Username for 'https://github.com'` during build** — git's way of
saying a repo returned 404/401, and it fell back to asking for credentials. It is
almost never an auth problem on your side. `Stability-AI/stablediffusion` was
deleted from GitHub in 2026 ([upstream issue #17204][17204]), so the `Dockerfile`
clones `w-e-w/stablediffusion` instead — the maintainer fork upstream's dev branch
moved to, carrying the identical pinned commit. If another of the five repos goes
the same way, override its `*_REPO` build arg rather than editing the `RUN` block:

```bash
docker compose build --build-arg K_DIFFUSION_REPO=https://github.com/someone/k-diffusion.git
```

The same override works at runtime via `.env`, because these ARG names match the
env vars `modules/launch_utils.py` reads. `GIT_TERMINAL_PROMPT=0` is set so a
future breakage reports "repository not found" instead of the credential prompt.

[17204]: https://github.com/AUTOMATIC1111/stable-diffusion-webui/issues/17204

**`Torch is not able to use GPU`** — the container can't see the GPU. Check
`docker run --rm --gpus all nvidia/cuda:12.1.1-base-ubuntu22.04 nvidia-smi`. To
run on CPU anyway, add `--skip-torch-cuda-test --use-cpu all --precision full
--no-half` to `COMMANDLINE_ARGS` (very slow).

**Permission errors on `./data`** — the container runs as root and writes
root-owned files. That's invisible on Windows bind mounts; on Linux, `sudo chown
-R $USER ./data` if you need to edit them from the host.

**Out of disk** — the build cache holds the pip downloads. `docker builder prune`
reclaims it.
