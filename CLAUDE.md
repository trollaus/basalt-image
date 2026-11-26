# AI assistant rules

- Keep file comments terse: a one-line "why" at most, and only on the
  non-obvious. The README already explains the pipeline, pins and
  digest flow - do not restate that in Dockerfile or workflow
  comments.
- Do not duplicate rules that live in the README or a CLAUDE.md
  elsewhere; point at the source instead of re-stating it.
- Keep this repo generic so any org can use it: no consumer-org
  references (a specific parent/infra repo, named hosts, sibling
  artifacts). The ghcr reference (`ghcr.io/trollaus/basalt-image`) and the example host var
  name (`basalt.image`) are the only org-specific bits.
- Commits: no Co-Authored-By or "Generated with" trailers.
