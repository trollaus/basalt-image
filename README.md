# trollaus/basalt-image

The Docker image for the `basalt` role in [trollaus/infra-ansible](https://github.com/trollaus/infra-ansible)
(`roles/containers/basalt`). The image is a repackaging of the upstream
[jesdga95/basalt](https://github.com/jesdga95/basalt) release artifact - no
custom code: the engine binary and its Python server are the release's
prebuilt `linux-x64` tarball (SHA-256-verified), and the Python venv is the
tarball's own pinned `requirements.txt`. The three `ARG` pins at the top of
`Dockerfile` (`BASALT_VERSION`, `BASALT_COMMIT`, `BASALT_SHA256`) are the
single source of truth for what is in the image.

Upstream publishes no container image - its own Dockerfile compiles the
engine from source with the CUDA toolchain, so this repo repackages the
release tarball instead (a thin wrapper: the tarball plus a pinned `nvidia/cuda`
runtime base and the venv's Python). The only org-specific content is the pin
set above and this pipeline.

The **~20 GB model packs** (e.g. the Inkling 2 Mini NVFP4 pack) are **not** in
the image: the role downloads them into the host's data dataset and mounts it
read-only at `/models`. A 20 GB image would be wrong - the pack stays a data
mount, re-downloadable from its pinned URL.

## Pipeline

```
new jesdga95/basalt release
  -> renovate.json bumps BASALT_VERSION (github-releases datasource; the
     release carries the prebuilt linux-x64 tarball)
     and the postUpgradeTask (.github/renovate/basalt-pins.mjs) fills
     BASALT_COMMIT + BASALT_SHA256 in the same PR
  -> the PR build (.github/workflows/basalt-image.yml) is the gate:
     docker build runs the Dockerfile's own checks - the release tarball's
     `sha256sum -c` against BASALT_SHA256, the entry-point self-check
     (bin/basalt present and executable, requirements.txt at the tree
     root), and the pip install of the tarball's own pinned requirements
  -> merge: CI publishes ghcr.io/trollaus/basalt-image:sha-<BASALT_COMMIT short>
     (plus :latest on master) and prints the image digest
  -> one-line digest bump of the role's image reference (basalt.image in
     juhovan/infra host_vars) -> deploy --tags basalt
```

The build is self-verifying on every run: a moved tag or a replaced release
asset changes nothing, because the tarball is verified against the
hard-coded SHA-256 and the entry-point self-check confirms the archive
layout. A bump that moves the version without the two companion pins fails
at the PR build check, not at the next deploy.

## Updating

Updates are driven by Renovate (default daily schedule, see `renovate.json`):

1. A run opens a PR bumping `BASALT_VERSION` to the newest release.
2. The PR's postUpgradeTask runs `node .github/renovate/basalt-pins.mjs`: it
   reads the bumped version, resolves the tag's commit and the release
   asset's `sha256` digest, and rewrites `BASALT_COMMIT` + `BASALT_SHA256` in
   place. The script is version-agnostic, so future bumps work without
   touching it.
   If the task did not run (hosted Mend Renovate blocks arbitrary commands
   unless allowlisted - the CI gate is the enforcement, and the PR body note
   says so), the PR build check catches the stale pins before merge.
3. Merge the PR: CI publishes the image and prints
   `basalt.image: ghcr.io/trollaus/basalt-image:sha-<short>@sha256:<digest>`
   at the end of the run.
4. Copy that line into the LLM host's host_vars in juhovan/infra
   (`basalt.image`; the role's README in trollaus/infra-ansible documents
   the var), and deploy `--tags basalt`.

Check the tarball's `requirements.txt` (pip pins) against a new release when a
bump lands (the comment above the `pip install` in the Dockerfile) and bump
them in the same PR - the venv installs the tarball's own pinned list, so a
version bump moves the engine and the pins together.

## Cost model

The workflow runs on `pull_request` and `push` **paths-filtered** to this
pipeline's own files (`Dockerfile`, the workflow, `renovate.json`, the pin
script), so it never runs on unrelated changes. The org's CI billing is
paid-plan minutes:

- **Renovate:** no schedule cap (the default daily check) on purpose:
  `jesdga95/basalt` is a per-release pipeline (each bump is a release
  tagged with a new prebuilt tarball), and per-release builds are
  acceptable - the release cadence is a few to a dozen a month (12 in the
  last ~4 weeks, incl. v0.5.6 -> v0.5.7 in one day). Each bump PR
  triggers one build (the paths filter means no build on anything else);
  if the cadence ever multiplies (daily-ship style), add a weekly schedule
  cap like `trollaus/abyss-image` has, and batch the bumps.
- **CI builds:** one `docker build` + `push` per merged bump PR and per merge
  to master - roughly one ~15-30 min build per release (the CUDA runtime base
  plus the ~170 MB tarball), so on the order of a few hundred billed
  minutes a month at the current release cadence.
- The `postUpgradeTask` runs outside the repo's CI (no CI minutes). On
  hosted Mend Renovate node ships with the runner, but arbitrary commands
  are blocked unless allowlisted - so by default the pin-filling script
  never runs there: every release bump needs `BASALT_COMMIT` +
  `BASALT_SHA256` filled by hand in the PR, and the CI build check is the
  gate (it fails the PR while the pins are stale). If the task runs on a
  self-hosted/enterprise Renovate runner instead, `installTools: {node: {}}`
  in the postUpgradeTasks entry fetches node there, since the slim
  self-hosted image lacks it.

## Pulling the image

The role pulls `ghcr.io/trollaus/basalt-image:sha-<short>@sha256:<digest>`
(pinned in host_vars; see the role's README, "Image"). The repo is public,
so the ghcr package is public by default and the host pulls it anonymously -
no registry login needed. If the owner ever makes the package private, the
host pulls it with a registry login under `docker_registry_logins` in the
parent repo's secret vars (precedent: le-certs, whose pin
`ghcr.io/trollaus/le-certs` is pulled the same way by the `docker` role
writing `/root/.docker/config.json`).
