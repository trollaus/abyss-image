# Abyss engine (the fork's release CUDA build, sm_86/89/120) + Python server, for DeepSeek V4.1 Flash, and the CPU
# image encoder. The tarball bundles cudart / cuBLAS / cuBLASLt; the host's nvidia driver (580+, 610+ recommended)
# provides libcuda. The ARGs below are what the image is; README.md has the pipeline and the pins.
# The engine's repo: a fork of zephel01/Abyss with DeepSeek V4.1 conversation slots (README).
ARG ABYSS_REPO=juhovan/Abyss
# renovate: datasource=github-releases depName=juhovan/Abyss
ARG ABYSS_VERSION=v1.3.206-slots.1
# The commit the tag points to (the tarball's PREBUILT.json names it too): the server is fetched by commit.
ARG ABYSS_COMMIT=dab4fd549b9ecf30664f7b4e06f05d62ac3d030a
# The release's abyss-engine-cuda-linux-x64.tar.gz; the release's own SHA256SUMS is not part of the check.
ARG ABYSS_ENGINE_SHA256=9efce411db43967fd8afe0f6089f70464c7836fce569aff8d7c263ba1f8475ae
# llama.cpp b11870, the first with DeepSeek V4.1's deepseek41v projector (the engine's own llama.cpp pin is older).
ARG LLAMA_CPP_VISION_COMMIT=74bca3950054eed1795f525cb9cf06bfe796492d

# strata-vision (tools/vision on llama.cpp's mtmd): the releases carry no image encoder. CPU only, AVX2 baseline.
FROM debian:trixie AS vision
ARG ABYSS_REPO
ARG ABYSS_COMMIT
ARG LLAMA_CPP_VISION_COMMIT
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git cmake ninja-build g++ \
    && rm -rf /var/lib/apt/lists/*
RUN git init /src && git -C /src remote add origin https://github.com/${ABYSS_REPO}.git \
    && git -C /src fetch --depth 1 origin ${ABYSS_COMMIT} && git -C /src checkout -f FETCH_HEAD \
    && git init /llama && git -C /llama remote add origin https://github.com/ggml-org/llama.cpp.git \
    && git -C /llama fetch --depth 1 origin ${LLAMA_CPP_VISION_COMMIT} && git -C /llama checkout -f FETCH_HEAD
RUN cmake -S /src/tools/vision -B /build -G Ninja -DCMAKE_BUILD_TYPE=Release -DLLAMA_DIR=/llama -DSTRATA_PORTABLE=ON \
    && cmake --build /build --target strata-vision

FROM debian:trixie
ARG ABYSS_REPO
ARG ABYSS_VERSION
ARG ABYSS_COMMIT
ARG ABYSS_ENGINE_SHA256
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates python3 python3-venv git curl \
    && rm -rf /var/lib/apt/lists/*
# A pinned fetch: the commit, not the tag; a shallow fetch of the commit is enough.
RUN git init /Abyss \
    && git -C /Abyss remote add origin https://github.com/${ABYSS_REPO}.git \
    && git -C /Abyss fetch --depth 1 origin ${ABYSS_COMMIT} \
    && git -C /Abyss checkout -f FETCH_HEAD
WORKDIR /Abyss
# Pinned to the venv measured on the trial build (2026-11-22); bump the pins with ABYSS_VERSION.
RUN python3 -m venv .venv \
    && .venv/bin/pip install --no-cache-dir \
        numpy==2.5.5 Jinja2==3.1.6 regex==2026.11.19 PyYAML==6.0.4 \
        tqdm==4.70.1 requests==2.34.2 pillow==13.0.0 psutil==7.2.2
# The prebuilt engine for this commit: downloaded for the release tag, verified against
# the hard-coded SHA-256, unpacked into build/ (its one top folder dropped, the strata
# link and the exec bits kept by the tarball), and the engine's build commit is checked
# against ABYSS_COMMIT so a bump that forgets the pin fails the build.
RUN mkdir -p build/.pin \
    && curl -fsSL "https://github.com/${ABYSS_REPO}/releases/download/${ABYSS_VERSION}/abyss-engine-cuda-linux-x64.tar.gz" \
       -o build/.pin/abyss-engine-cuda-linux-x64.tar.gz \
    && echo "${ABYSS_ENGINE_SHA256}  build/.pin/abyss-engine-cuda-linux-x64.tar.gz" | sha256sum -c \
    && tar xzf build/.pin/abyss-engine-cuda-linux-x64.tar.gz -C build/.pin \
    && mv build/.pin/abyss-engine-cuda-linux-x64/* build/ \
    && rm -rf build/.pin \
    && ABYSS_COMMIT=${ABYSS_COMMIT} .venv/bin/python -c 'import json, os, sys; c = json.load(open("build/PREBUILT.json"))["commit"]; want = os.environ["ABYSS_COMMIT"]; sys.stderr.write("the engine was built from %s, but the server is pinned to %s: update ABYSS_COMMIT\n" % (c, want)) if c != want else None; sys.exit(0 if c == want else 1)' \
    && .venv/bin/python -m py_compile serve/server.py tools/iq_pack.py
COPY --from=vision /build/bin/strata-vision build/strata-vision
EXPOSE 8082
CMD [".venv/bin/python", "serve/server.py", "--engine", "strata", "--config", "abyss-dsv41.json", "--port", "8082"]
