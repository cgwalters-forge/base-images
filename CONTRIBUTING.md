# Contributing to fedora-bootc base images

## Prerequisites

Everything revolves around our Containerfile, but there's
a high level wrapper in `Justfile` which you should use.
So installing `podman` (or `buildah`) and `just` are strongly recommended.

## Building and testing

Run `just --list` to see available targets and `just show-config` to
see current settings. The Justfile is also what CI invokes, so anything
you run locally is the same as what runs in the pipeline.

Configuration is via environment variables — see the comments at the
top of the `Justfile` for the full list. For example:

```bash
just build                                    # defaults
TIER=minimal just build                       # different tier
FEDORA_VERSION=43 just test                   # different Fedora version
BUILDER=podman just build                     # use podman instead of buildah
just ci                                       # full CI run (validate + test all tiers)
```
