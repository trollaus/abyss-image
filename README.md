# trollaus/abyss-image

The Docker image consumed by an `abyss` ansible container role - the role
pulls a digest-pinned reference of this image and never builds on the host.
The image packages the release artifacts of
[juhovan/Abyss](https://github.com/juhovan/Abyss), a fork of
[zephel01/Abyss](https://github.com/zephel01/Abyss) (below, "The fork"). This
repo adds no code: the server is fetched from the pinned commit, the engine is
the release's prebuilt CUDA tarball, and the Python venv is pinned. One program
is compiled here: the CPU image encoder `strata-vision` (Abyss's
`tools/vision` at the same commit, on llama.cpp's mtmd at
`LLAMA_CPP_VISION_COMMIT`, b11870 - the first with DeepSeek V4.1's
`deepseek41v` projector), because the releases carry none. The `ARG` pins at
the top of `Dockerfile` (`ABYSS_REPO`, `ABYSS_VERSION`, `ABYSS_COMMIT`,
`ABYSS_ENGINE_SHA256`, `LLAMA_CPP_VISION_COMMIT`) are the single source of
truth for what is in the image. Renovate does not track
`LLAMA_CPP_VISION_COMMIT` (llama.cpp tags several builds a day); move it by
hand when a release's encoder needs a newer one.

## Pipeline

```
new juhovan/Abyss release
  -> weekly: renovate.json bumps ABYSS_VERSION (github-releases datasource)
     and the postUpgradeTask (.github/renovate/abyss-pins.mjs) fills
     ABYSS_COMMIT + ABYSS_ENGINE_SHA256 in the same PR
  -> the PR build (.github/workflows/abyss-image.yml) is the gate:
     docker build runs the Dockerfile's own checks - the engine tarball's
     `sha256sum -c` against ABYSS_ENGINE_SHA256, the PREBUILT.json commit
     check against ABYSS_COMMIT, the pip install, py_compile
  -> merge: CI publishes ghcr.io/trollaus/abyss-image:<ABYSS_VERSION> (the fork
     release, eg. v1.3.206-slots.1), :sha-<ABYSS_COMMIT short> and :latest, and
     prints the pinned image line
  -> the consuming role's Renovate proposes the new release tag (or the line is
     pasted into its static docker-compose.yml) -> deploy --tags abyss
```

The build is self-verifying on every run: a moved tag or a replaced release
asset changes nothing, because the server is fetched by commit and the
tarball is verified against the hard-coded SHA-256. A bump that moves the
version without the two companion pins fails at the PR build check, not at
the next deploy.

## The fork

juhovan/Abyss carries one change on top of an upstream release: DeepSeek V4.1
conversation slots (`STRATA_GLM_SLOTS`). Upstream keeps a single V4.1
conversation, so agents whose turns interleave re-read each other's whole
prompt on every turn; the fork sets each conversation aside in host RAM and
takes it back when its next turn arrives, as upstream already does for other
models.

- Its branch `v41-conv-slots` is the change rebased on an upstream release
  tag. A fork release is that branch's tip tagged `v<upstream>-slots.<n>`
  (e.g. `v1.3.206-slots.1`).
- Pushing the tag runs the fork's copy of upstream's `prebuilt.yml`: it builds
  the Linux and Windows engines (CUDA 13.3, sm_86/89/120a) and attaches them
  and `SHA256SUMS` to the tag's release, the same assets an upstream release
  has. The engine's `PREBUILT.json` then names the tagged commit, which the
  Dockerfile checks against `ABYSS_COMMIT`.
- Following upstream is a manual step: rebase the branch on a newer upstream
  tag, test it, tag the next `-slots.<n>` release. Renovate here then opens
  the bump PR as for any release.

## Updating

Updates are driven by Renovate (weekly schedule, see `renovate.json`):

1. A weekly run opens a PR bumping `ABYSS_VERSION` to the newest fork release
   (`ignoreUnstable` is off: the `-slots.<n>` suffix reads as a pre-release).
2. The PR's postUpgradeTask runs `node .github/renovate/abyss-pins.mjs`: it
   reads `ABYSS_REPO` and the bumped version, resolves the tag's commit and the
   release's `SHA256SUMS`, and rewrites `ABYSS_COMMIT` + `ABYSS_ENGINE_SHA256`
   in place. It refuses to run when the Renovate comment's `depName` is not
   `ABYSS_REPO`. If the task did not run (hosted Mend Renovate blocks arbitrary
   commands unless allowlisted - the CI gate is the enforcement, and the PR
   body note says so), the PR build check catches the stale pins before merge.
3. Merge the PR: CI publishes the image and prints
   `image: ghcr.io/trollaus/abyss-image:<ABYSS_VERSION>@sha256:<digest>` at the
   end of the run. A manual run of the workflow on master (workflow_dispatch)
   rebuilds and re-publishes the same tags.
4. The consuming role's Renovate proposes the new release tag (it orders
   `v<x.y.z>-slots.<n>`); or put the printed line in its static
   `docker-compose.yml`. Then deploy `--tags abyss`.

Check the pip pins against a new release when a bump lands (the comment above
the `pip install` in the Dockerfile) and bump them in the same PR.

## Cost model

This repo and the fork are public, so their workflows run on GitHub's
standard hosted runners at no cost; neither uses larger runners.

- **This repo:** the workflow runs on `pull_request` and `push`
  **paths-filtered** to this pipeline's own files (`Dockerfile`, the workflow,
  `renovate.json`, the pin script), so it never runs on unrelated PRs. A
  `docker build` is a ~2-6 min job (a pinned `debian:trixie` base, two git
  fetches, the encoder's CPU compile, a pinned pip list and the engine tarball
  download).
- **The fork:** one release build per tag, 1-3 hours (the CUDA compile, Linux
  and Windows). The job limit of a hosted runner is 6 hours.
- **Renovate (hosted):** the weekly schedule opens at most one PR a week. The
  `postUpgradeTask` runs outside the repo's CI. If it ever runs on a
  self-hosted/enterprise Renovate runner instead, `installTools: {node: {}}`
  in the postUpgradeTasks entry fetches node there, since the slim
  self-hosted image lacks it.

## Pulling the image

The consuming role pins
`ghcr.io/trollaus/abyss-image:<ABYSS_VERSION>@sha256:<digest>` in its static
`docker-compose.yml` (see the role's README, "Image"). This repo is public, so
the ghcr package is public and the host pulls it anonymously - no registry
login needed. If the owner ever makes the package private, the host pulls it
with a registry login (e.g. a `docker_registry_logins` entry in the parent
repo's secret vars, rendered into the host's docker config).
