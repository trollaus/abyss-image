#!/usr/bin/env node
// Fill in the Abyss Dockerfile's companion pins after Renovate has bumped
// ABYSS_VERSION: the tag's commit (ABYSS_COMMIT, the server code is fetched by
// commit) and the release's engine tarball SHA-256 (ABYSS_ENGINE_SHA256, the
// tarball is verified against it in the build). Without them a version-only
// bump builds a broken image; the CI build + publish check
// (.github/workflows/abyss-image.yml) fails such a PR instead.
//
// Wired up as a postUpgradeTask in renovate.json. On Mend-hosted Renovate,
// postUpgradeTasks commands are blocked unless allowlisted (docs:
// docs.renovatebot.com/mend-hosted/faq, "How can I run arbitrary commands"),
// so this is best-effort: if the task does not run, the CI gate is the
// enforcement, and the PR body note says so.
//
// Version-agnostic: it reads the ABYSS_VERSION already in the Dockerfile, so
// every future bump works without touching this script.
//
// Usage: node .github/renovate/abyss-pins.mjs [dockerfile]
// The postUpgradeTask working directory is the repository root, so the
// default path (the Dockerfile at the repo root) is relative to it.
//
// If the task is ever allowlisted on a self-hosted/enterprise Renovate, add
// installTools: {node: {}} to the postUpgradeTasks entry (plus constraints:
// {node: "^22"} to pin the version - the tool objects expose no
// configurability, versioning goes through constraints) - the self-hosted
// slim image lacks node, while Mend-hosted ships it.

import { readFile, writeFile } from "node:fs/promises";

const repo = "zephel01/Abyss";
const engineAsset = "abyss-engine-cuda-linux-x64.tar.gz";

// Timeout + retry on the API calls: a 429/5xx body would otherwise surface as
// a misleading "tag not found" instead of the real failure.
async function getJson(url) {
  let res;
  for (let attempt = 1; attempt <= 4; attempt++) {
    res = await fetch(url, { signal: AbortSignal.timeout(30_000) });
    if (res.status === 429 || res.status >= 500) {
      await new Promise((r) => setTimeout(r, 5_000 * attempt));
      continue;
    }
    if (!res.ok)
      throw new Error(`GET ${url} failed: HTTP ${res.status} ${res.statusText}`);
    return res.json();
  }
  throw new Error(`GET ${url} failed: HTTP ${res.status} after retries`);
}

const dfPath = process.argv[2] ?? "Dockerfile";
const text = await readFile(dfPath, "utf8");

const version = text.match(/^ARG ABYSS_VERSION=(\S+)\s*$/m)?.[1];
if (!version) throw new Error(`no "ARG ABYSS_VERSION=" line in ${dfPath}`);

const ref = await getJson(
  `https://api.github.com/repos/${repo}/git/ref/tags/${version}`
);
if (!ref.object?.sha) throw new Error(`tag ${version} not found in ${repo}`);

// An annotated tag points at a tag object that holds the commit; a
// lightweight tag points at the commit directly.
let commit = ref.object.sha;
if (ref.object.type === "tag") {
  const tag = await getJson(
    `https://api.github.com/repos/${repo}/git/tags/${commit}`
  );
  if (!tag.object?.sha) throw new Error(`tag object ${commit} has no commit`);
  commit = tag.object.sha;
}

// The sha256 of the engine tarball, from the release's own SHA256SUMS asset.
const release = await getJson(
  `https://api.github.com/repos/${repo}/releases/tags/${version}`
);
const sumsAsset = release.assets?.find((a) => a.name === "SHA256SUMS");
if (!sumsAsset) throw new Error(`release ${version} has no SHA256SUMS asset`);
let sums;
for (let attempt = 1; attempt <= 4; attempt++) {
  const res = await fetch(sumsAsset.browser_download_url, {
    signal: AbortSignal.timeout(120_000),
  });
  if (res.status === 429 || res.status >= 500) {
    await new Promise((r) => setTimeout(r, 5_000 * attempt));
    continue;
  }
  if (!res.ok)
    throw new Error(`GET ${sumsAsset.browser_download_url} failed: HTTP ${res.status}`);
  sums = await res.text();
  break;
}
if (sums === undefined)
  throw new Error(`GET ${sumsAsset.browser_download_url} failed after retries`);
const line = sums
  .split("\n")
  .map((l) => l.trim())
  .find((l) => l.split(/\s+/).pop() === engineAsset);
const sha = line?.split(/\s+/)[0];
if (!/^[0-9a-f]{64}$/.test(sha ?? ""))
  throw new Error(`SHA256SUMS of release ${version} has no entry for ${engineAsset}`);

// Rewrite the two pins in place; both must be present, or refuse to write a
// half-updated Dockerfile.
if (!/^ARG ABYSS_COMMIT=\S+$/m.test(text) || !/^ARG ABYSS_ENGINE_SHA256=\S+$/m.test(text))
  throw new Error(`missing ABYSS_COMMIT / ABYSS_ENGINE_SHA256 ARG in ${dfPath}`);
await writeFile(
  dfPath,
  text
    .replace(/^ARG ABYSS_COMMIT=\S+$/m, `ARG ABYSS_COMMIT=${commit}`)
    .replace(/^ARG ABYSS_ENGINE_SHA256=\S+$/m, `ARG ABYSS_ENGINE_SHA256=${sha}`)
);
console.log(
  `abyss-pins: ${version} -> ABYSS_COMMIT=${commit} ABYSS_ENGINE_SHA256=${sha}`
);
