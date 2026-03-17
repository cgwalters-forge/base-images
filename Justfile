# Development entry point for fedora-bootc base images.
# Run `just --list` to see available targets.
# See CONTRIBUTING.md for more information.
# --------------------------------------------------------------------

# Content tier: standard (default), minimal, minimal-plus, iot
tier := env("TIER", "standard")
# Fedora version: rawhide (default), 43, 44, etc.
fedora_version := env("FEDORA_VERSION", "rawhide")
# Container build tool
builder := env("BUILDER", "buildah")
# Extra arguments for the builder
builder_extra := env("BUILDER_EXTRA", "")
# Output image name
image := "localhost/fedora-bootc"

# These are required for the nested containerization used by rpm-ostree
# inside the Containerfile.
priv_args := "--security-opt=label=disable --cap-add=all --device /dev/fuse"

# Internal
_build_cmd := builder + " build"
_tag := image + if tier == "standard" { "" } else { ":" + tier }
_base_image := "quay.io/fedora/fedora:" + fedora_version
_version_args := if fedora_version == "rawhide" { "" } else { "--build-arg=REPOS_IMAGE=" + _base_image + " --build-arg=BUILDER_IMAGE=" + _base_image }

# ============================================================================
# Core targets
# ============================================================================

# Build the container image
[group('core')]
build: _check-tier
    {{_build_cmd}} -f Containerfile --no-cache \
        -t {{_tag}} {{priv_args}} \
        {{_version_args}} {{builder_extra}} \
        --build-arg=MANIFEST=fedora-{{tier}} .

# Build and test
[group('core')]
test: build
    #!/usr/bin/env bash
    set -xeuo pipefail
    {{_build_cmd}} -f tests/rootfs/Dockerfile -t localhost/test --from {{_tag}} tests/rootfs
    # The derive and sysusers tests only apply to the standard tier
    if [ "{{tier}}" = "standard" ]; then
        {{_build_cmd}} -f tests/Containerfile.test-derive --no-cache \
            -t localhost/fedora-bootc-derived {{priv_args}} {{builder_extra}} tests
        {{_build_cmd}} -f tests/Containerfile.test-sysusers --no-cache \
            -t localhost/fedora-bootc-derived {{priv_args}} {{builder_extra}} tests
    fi

# Run validation checks (whitespace, shellcheck, YAML)
[group('core')]
validate:
    #!/usr/bin/env bash
    set -xeuo pipefail
    ./ci/find-whitespace
    ./ci/shellcheck
    ./ci/validate

# Show current configuration
[group('core')]
show-config:
    @echo "TIER={{tier}}"
    @echo "FEDORA_VERSION={{fedora_version}}"
    @echo "BUILDER={{builder}}"
    @echo "image tag={{_tag}}"
    @echo "base image={{_base_image}}"

# ============================================================================
# CI targets (used by .gitlab-ci.yml)
# ============================================================================

# Run all CI checks: validate + build and test all tiers
[group('ci')]
ci: validate
    just tier=minimal test
    just tier=minimal-plus test
    just tier=standard test

# ============================================================================
# Internal
# ============================================================================

[private]
_check-tier:
    @test -f fedora-{{tier}}.yaml || { echo "error: unknown tier '{{tier}}' (valid: standard, minimal, minimal-plus, iot)"; exit 1; }
