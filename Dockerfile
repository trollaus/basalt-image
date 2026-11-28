# Basalt engine (github.com/jesdga95/basalt, MIT) + its Python server, for LLM
# inference on NVIDIA Blackwell GPUs (sm_120).
#
# The image is published by this repo's CI (.github/workflows/basalt-image.yml) and
# pulled by the consuming side - e.g. an ansible container role - which pins
# the reference in its host vars. The three ARGs below are the single source of truth for what is in the image;
# a rebuild is what the pins describe.
#
# BASALT_VERSION (a jesdga95/basalt release tag) is tracked by renovate.json (datasource
# github-releases: the release carries the prebuilt linux-x64 tarball). When a bump lands, the
# postUpgradeTask (.github/renovate/basalt-pins.mjs) rewrites the two companion pins - the
# commit the tag points to (BASALT_COMMIT, the image's tag) and the tarball's SHA-256
# (BASALT_SHA256) - in the same PR; CI then builds and publishes the image. If the task did
# not run, the PR build check catches the stale pins before merge (the tarball verifies
# against the hard-coded SHA-256).
#
# The image is a repackaging of the upstream release artifact, not custom code: the engine
# binary and the Python server are the release's prebuilt linux-x64 tarball, verified against
# the hard-coded SHA-256, and the venv takes the tarball's own pinned requirements.txt.
# Upstream publishes no container image - its own Dockerfile compiles the engine from source
# with the CUDA toolchain, which is why this repackages the tarball instead.
#
# The ~20 GB model packs (eg. Inkling 2 Mini NVFP4) are NOT in the image: the role downloads
# them into the host's data dataset and mounts it read-only at /models. The image is the
# pinned tarball plus its runtime deps only.
#
# The host needs a CUDA-13 driver and an NVIDIA Blackwell GPU (sm_120; the GB10 Arm build is
# a different tarball, this image is x86-64). The cards reach the container through the
# nvidia container runtime; the role's compose reservation selects which cards, and the
# rendered config names them by their in-container number (the first reserved card is device
# 0).
#
# Mounts (from the role's docker-compose):
#   /config    the role's config directory, read-only; the entrypoint serves
#              /config/basalt_config.json (version 2, rendered by the role)
#   /models    the .basalt model packs, read-only; the config names the pack
#              by its mount path
#   /data      HOME: the server's per-model folder under ~/.cache/basalt
#              (its engine log and, when conversation-cache-disk-mib is on,
#              that tier)
#
# The tree under /opt/basalt is the release archive's: a binary finds its
# install root as the directory above bin/, reads the expert profiles from
# data/profiles, execs the python of .venv for `basalt serve` (--python
# defaults to .venv/bin/python in the source tree), and looks for the
# basalt-vision sidecar beside itself, so it stays one flat tree at one
# fixed path (the venv's own scripts name it absolutely).

FROM nvidia/cuda:13.5.0-runtime-ubuntu24.04
# renovate: datasource=github-releases depName=jesdga95/basalt
ARG BASALT_VERSION=0.5.7
# The commit the release tag points at: the image is tagged sha-<BASALT_COMMIT short>.
ARG BASALT_COMMIT=400b411c58031d064812ea21a259b2381acdaa3e
# The SHA-256 of the release's basalt-v${BASALT_VERSION}-linux-x64.tar.gz,
# read from the release asset's digest on 2026-11-25.
ARG BASALT_SHA256=a390c775c41d54454ca21c1e547855bf6c251732533ca387e8b890e538090525

ENV HOME=/data \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/basalt/bin:$PATH

# python3 + a venv: `basalt serve` execs the venv's python for its server.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/basalt

# Pinned fetch: the release tag, verified against the hard-coded SHA-256, so
# a moved tag or replaced release asset cannot change what is installed.
# The archive's top folder (basalt-v${BASALT_VERSION}-linux-x64) is dropped,
# and the tree's entry points are checked so a renamed asset fails the build.
RUN curl -fsSL -o /tmp/basalt.tar.gz \
        "https://github.com/jesdga95/basalt/releases/download/v${BASALT_VERSION}/basalt-v${BASALT_VERSION}-linux-x64.tar.gz" \
    && echo "${BASALT_SHA256}  /tmp/basalt.tar.gz" | sha256sum -c - \
    && tar xzf /tmp/basalt.tar.gz -C /opt/basalt --strip-components=1 \
    && rm /tmp/basalt.tar.gz \
    && test -x /opt/basalt/bin/basalt -a -f /opt/basalt/requirements.txt

# The tarball's own pinned requirements, so the tree is one verified
# artifact: a version bump moves both the engine and the pins together.
RUN python3 -m venv /opt/basalt/.venv \
    && /opt/basalt/.venv/bin/pip install --no-cache-dir -r /opt/basalt/requirements.txt

# The served port is server.port in the config (default 8080); nginx reaches
# it on the nginx-basalt network.
EXPOSE 8080

# Serve the mounted config, bound to 0.0.0.0 so it is reachable from the
# nginx network. Arguments after the image name follow the entrypoint. When
# basalt.api_key is set, the role passes --api-key-file /config/api_key (the
# key file is written 0600 by the role's tasks), which keeps the key out of
# the process list; a CLI --api-key would leave it in `docker ps`, and the
# key itself can only be given on the command line, never in the config
# file.
ENTRYPOINT ["basalt", "serve", "--config", "/config/basalt_config.json", "--host", "0.0.0.0"]
