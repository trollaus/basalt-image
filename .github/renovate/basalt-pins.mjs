#!/usr/bin/env node
// Fill in the Basalt Dockerfile's companion pins after Renovate has bumped
// BASALT_VERSION: the tag's commit (BASALT_COMMIT, the image is tagged
// sha-<BASALT_COMMIT short>) and the release's linux-x64 tarball SHA-256
// (BASALT_SHA256, the tarball is verified against it in the build). Without
// them a version-only bump builds a broken image; the CI build + publish
// check (.github/workflows/basalt-image.yml) fails such a PR instead.
//
// Wired up as a postUpgradeTask in renovate.json. On Mend-hosted Renovate,
// postUpgradeTasks commands are blocked unless allowlisted (docs:
// docs.renovatebot.com/mend-hosted/faq, "How can I run arbitrary commands"),
// so this is best-effort: if the task does not run, the CI gate is the
// enforcement, and the PR body note says so.
//
// Version-agnostic: it reads the BASALT_VERSION already in the Dockerfile, so
// every future bump works without touching this script.
//
// Usage: node .github/renovate/basalt-pins.mjs [dockerfile]
// The postUpgradeTask working directory is the repository root, so the
// default path (the Dockerfile at the repo root) is relative to it.
//
// Node version: the script needs node >= 18 (top-level await, global fetch,
// AbortSignal.timeout - it uses fetch + AbortSignal.timeout(30_000)); the
// GitHub runner's node satisfies it (the workflow's `node --check` step runs
// it), and Mend-hosted Renovate ships node with its runner. On a
// self-hosted/enterprise runner, installTools: {node: {}} (already declared
// in renovate.json's postUpgradeTasks entry) fetches node, since the slim
// self-hosted image lacks it. The tool objects take no version, so pinning
// the runner's node is a constraints matter (constraints.node), not an
// installTools one.

import { readFile, writeFile } from "node:fs/promises";

const repo = "jesdga95/basalt";

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

const version = text.match(/^ARG BASALT_VERSION=(\S+)\s*$/m)?.[1];
if (!version) throw new Error(`no "ARG BASALT_VERSION=" line in ${dfPath}`);

// The ARG value is the bare release version (0.5.7); the git tag and the
// release's tag_name carry the v- prefix (v0.5.7). The ARG is bare on
// purpose: renovate's github-releases datasource matches the bare version.
const tag = version.startsWith("v") ? version : `v${version}`;

const ref = await getJson(
  `https://api.github.com/repos/${repo}/git/ref/tags/${tag}`
);
if (!ref.object?.sha) throw new Error(`tag ${tag} not found in ${repo}`);

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

// The sha256 of the linux-x64 tarball, from the release's own asset digest
// (GitHub reports the content SHA-256 there; the tarball name is fixed by the
// version). No SHA256SUMS download needed - the asset digest is authoritative.
const release = await getJson(
  `https://api.github.com/repos/${repo}/releases/tags/${tag}`
);
const assetName = `basalt-v${version}-linux-x64.tar.gz`;
const asset = release.assets?.find((a) => a.name === assetName);
if (!asset?.digest)
  throw new Error(`release ${version} has no ${assetName} asset with a digest`);
const sha = asset.digest.replace(/^sha256:/, "");
if (!/^[0-9a-f]{64}$/.test(sha))
  throw new Error(`${assetName} digest of release ${version} is not a sha256`);

// Rewrite the two pins in place; both must be present, or refuse to write a
// half-updated Dockerfile.
if (!/^ARG BASALT_COMMIT=\S+$/m.test(text) || !/^ARG BASALT_SHA256=\S+$/m.test(text))
  throw new Error(`missing BASALT_COMMIT / BASALT_SHA256 ARG in ${dfPath}`);
await writeFile(
  dfPath,
  text
    .replace(/^ARG BASALT_COMMIT=\S+$/m, `ARG BASALT_COMMIT=${commit}`)
    .replace(/^ARG BASALT_SHA256=\S+$/m, `ARG BASALT_SHA256=${sha}`)
);
console.log(
  `basalt-pins: ${version} -> BASALT_COMMIT=${commit} BASALT_SHA256=${sha}`
);
