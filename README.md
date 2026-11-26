# trollaus/abyss-image

The Docker image consumed by an `abyss` ansible container role - the role
pulls a digest-pinned reference of this image and never builds on the host.
The image repackages upstream release artifacts of
[zephel01/Abyss](https://github.com/zephel01/Abyss) - no custom code: the server
is fetched from the pinned commit, the engine is the release's prebuilt CUDA
tarball, and the Python venv is pinned. The three `ARG` pins at the top of
`Dockerfile` (`ABYSS_VERSION`, `ABYSS_COMMIT`, `ABYSS_ENGINE_SHA256`) are the
single source of truth for what is in the image.

## Pipeline

```
new zephel01/Abyss release
  -> weekly: renovate.json bumps ABYSS_VERSION (github-releases datasource)
     and the postUpgradeTask (.github/renovate/abyss-pins.mjs) fills
     ABYSS_COMMIT + ABYSS_ENGINE_SHA256 in the same PR
  -> the PR build (.github/workflows/abyss-image.yml) is the gate:
     docker build runs the Dockerfile's own checks - the engine tarball's
     `sha256sum -c` against ABYSS_ENGINE_SHA256, the PREBUILT.json commit
     check against ABYSS_COMMIT, the pip install, py_compile
  -> merge: CI publishes ghcr.io/trollaus/abyss-image:sha-<ABYSS_COMMIT short>
     (plus :latest on master) and prints the image digest
  -> one-line digest bump of the role's image reference (abyss.image in
     the parent repo's host_vars) -> deploy --tags abyss
```

The build is self-verifying on every run: a moved tag or a replaced release
asset changes nothing, because the server is fetched by commit and the
tarball is verified against the hard-coded SHA-256. A bump that moves the
version without the two companion pins fails at the PR build check, not at
the next deploy.

## Updating

Updates are driven by Renovate (weekly schedule, see `renovate.json`):

1. A weekly run opens a PR bumping `ABYSS_VERSION` to the newest release.
2. The PR's postUpgradeTask runs `node .github/renovate/abyss-pins.mjs`: it
   reads the bumped version, resolves the tag's commit and the release's
   `SHA256SUMS`, and rewrites `ABYSS_COMMIT` + `ABYSS_ENGINE_SHA256` in place.
   The script is version-agnostic, so future bumps work without touching it.
   If the task did not run (hosted Mend Renovate blocks arbitrary commands
   unless allowlisted - the CI gate is the enforcement, and the PR body note
   says so), the PR build check catches the stale pins before merge.
3. Merge the PR: CI publishes the image and prints
   `abyss.image: ghcr.io/trollaus/abyss-image:sha-<short>@sha256:<digest>` at the
   end of the run.
4. Copy that line into the host's host_vars in the parent repo
   (`abyss.image`; the consuming role documents the var), and deploy
   `--tags abyss`.

Check the pip pins against a new release when a bump lands (the comment above
the `pip install` in the Dockerfile) and bump them in the same PR.

## Cost model

The workflow runs on `pull_request` and `push` **paths-filtered** to this
pipeline's own files (`Dockerfile`, the workflow, `renovate.json`, the pin
script), so it never runs on unrelated PRs. The org's CI billing is
paid-plan minutes:

- **Renovate (hosted):** the weekly schedule opens at most one PR a week.
  `zephel01/Abyss` ships ~4.7 releases a day; capping the schedule at
  weekly keeps that cadence down (daily checks would multiply the CI builds
  by ~7). A PR build runs only on the bump PRs.
- **CI builds:** a `docker build` is a ~1-5 min job (the layers are small:
  a pinned `debian:trixie` base, one git fetch, a pinned pip list, and the
  ~hundreds-of-MB engine tarball download) even cold. That is one build per
  bump PR and one per merge to master - roughly 5-10 builds a month,
  **~20-50 billed minutes/month**, plus any manual pin-fix PRs.
- The `postUpgradeTask` runs outside the repo's CI (no CI minutes). On
  hosted Mend Renovate node ships with the runner, so the task runs as-is
  (arbitrary commands are blocked unless allowlisted - the CI gate is the
  enforcement). If the task runs on a self-hosted/enterprise Renovate runner
  instead, `installTools: {node: {}}` in the postUpgradeTasks entry fetches
  node there, since the slim self-hosted image lacks it.

## Pulling the image

The role pulls `ghcr.io/trollaus/abyss-image:sha-<short>@sha256:<digest>`
(pinned in host_vars; see the role's README, "Image"). This repo is
public, so the ghcr package is public by default and the host pulls it
anonymously - no registry login needed. If the owner ever makes the
package private, the host pulls it with a registry login (e.g. a
`docker_registry_logins` entry in the parent repo's secret vars, rendered
into the host's docker config).
