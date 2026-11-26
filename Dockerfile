# Abyss engine (prebuilt CUDA binary, sm_86/89/120) + Python server, for DeepSeek V4.1 Flash.
# The prebuilt engine bundles the CUDA libraries it loads (cudart, cuBLAS, cuBLASLt); the
# host's nvidia driver (580+, 610+ recommended) provides libcuda.
#
# The image is published by this repo's CI (.github/workflows/abyss-image.yml) and
# pulled by the consuming side - e.g. an ansible container role - which pins
# the reference in its host vars. The three ARGs below are the single source of truth for what is in the image;
# a rebuild is what the pins describe.
#
# ABYSS_VERSION (an Abyss release tag) is tracked by renovate.json (datasource
# github-releases: a tag without a release is not a buildable version). When a bump lands,
# the postUpgradeTask (.github/renovate/abyss-pins.mjs) rewrites the two companion pins -
# the commit the tag points to (ABYSS_COMMIT, the server code) and the tarball's SHA-256
# (ABYSS_ENGINE_SHA256) - in the same PR; CI then builds and publishes the image. If the
# task did not run, the PR build check catches the stale pins before merge. Check the pip
# pins below against a new release and bump them in the same PR.
#
# The image is a repackaging of upstream release artifacts, not custom code: the server is
# fetched from a pinned commit, the engine is the release's prebuilt tarball, and the venv
# is pinned. The embedded checks keep a moved tag or a replaced release asset from changing
# what is installed: the tarball is verified against the hard-coded SHA-256, and the engine's
# PREBUILT.json commit is checked against ABYSS_COMMIT.
FROM debian:trixie
# renovate: datasource=github-releases depName=zephel01/Abyss
ARG ABYSS_VERSION=v1.3.206
# The commit v1.3.206's tag points to (the engine tarball's PREBUILT.json pins the
# same commit): the server code is fetched by commit, so a moved tag changes nothing.
ARG ABYSS_COMMIT=981ce5cf8b94be209a40765d6d59c1f822992e9a
# The SHA-256 of the release's abyss-engine-cuda-linux-x64.tar.gz. The download is
# verified against it; the release's own SHA256SUMS is not part of the check.
ARG ABYSS_ENGINE_SHA256=812eb6f86f0d97e36d71908e143a02a45dad2c5a32aa06fd3e8481168071ae9f
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates python3 python3-venv git curl \
    && rm -rf /var/lib/apt/lists/*
# A pinned fetch: the commit, not the tag; a shallow fetch of the commit is enough.
RUN git init /Abyss \
    && git -C /Abyss remote add origin https://github.com/zephel01/Abyss.git \
    && git -C /Abyss fetch --depth 1 origin ${ABYSS_COMMIT} \
    && git -C /Abyss checkout -f FETCH_HEAD
WORKDIR /Abyss
# Pinned to the venv measured on the trial build (2026-11-22); bump the pins with ABYSS_VERSION.
# cmake/ninja are only needed for a source build, which this image never does.
RUN python3 -m venv .venv \
    && .venv/bin/pip install --no-cache-dir \
        numpy==2.5.5 Jinja2==3.1.6 regex==2026.11.19 PyYAML==6.0.4 \
        tqdm==4.70.1 requests==2.34.2 pillow==13.0.0 psutil==7.2.2
# The prebuilt engine for this commit: downloaded for the release tag, verified against
# the hard-coded SHA-256, unpacked into build/ (its one top folder dropped, the strata
# link and the exec bits kept by the tarball), and the engine's build commit is checked
# against ABYSS_COMMIT so a bump that forgets the pin fails the build.
RUN mkdir -p build/.pin \
    && curl -fsSL "https://github.com/zephel01/Abyss/releases/download/${ABYSS_VERSION}/abyss-engine-cuda-linux-x64.tar.gz" \
       -o build/.pin/abyss-engine-cuda-linux-x64.tar.gz \
    && echo "${ABYSS_ENGINE_SHA256}  build/.pin/abyss-engine-cuda-linux-x64.tar.gz" | sha256sum -c \
    && tar xzf build/.pin/abyss-engine-cuda-linux-x64.tar.gz -C build/.pin \
    && mv build/.pin/abyss-engine-cuda-linux-x64/* build/ \
    && rm -rf build/.pin \
    && ABYSS_COMMIT=${ABYSS_COMMIT} .venv/bin/python -c 'import json, os, sys; c = json.load(open("build/PREBUILT.json"))["commit"]; want = os.environ["ABYSS_COMMIT"]; sys.stderr.write("the engine was built from %s, but the server is pinned to %s: update ABYSS_COMMIT\n" % (c, want)) if c != want else None; sys.exit(0 if c == want else 1)' \
    && .venv/bin/python -m py_compile serve/server.py tools/iq_pack.py
EXPOSE 8082
CMD [".venv/bin/python", "serve/server.py", "--engine", "strata", "--config", "abyss-dsv41.json", "--port", "8082"]
