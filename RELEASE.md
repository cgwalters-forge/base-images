# Fedora Base Bootc Container Publishing

## Overview

The `fedora-base-bootc` image is published via **two parallel mechanisms**:

1. **Pungi-IoT + cloud-image-uploader** → `quay.io/fedora/fedora-bootc` (Production)
2. **Konflux** → `quay.io/bootc-devel/fedora-bootc-*` (Development)

The goal is to move to Konflux and deprecate the Pungi-IoT mechanism.

---

## Part 1: Production Flow (Pungi-IoT)

### Repositories

| Repository | URL | Purpose |
|------------|-----|---------|
| base-images | https://pagure.io/fedora-iot/base-images | Image definition (treefiles, packages) |
| pungi-iot | https://pagure.io/fedora-iot/pungi-iot | Compose configuration |
| cloud-image-uploader | https://pagure.io/cloud-image-uploader | Uploads images to registries |
| ansible | https://pagure.io/fedora-infra/ansible | Infrastructure deployment |

### Compose Cadence

| Compose | Schedule | Host |
|---------|----------|------|
| IoT Rawhide | **Nightly** | compose-iot01.rdu3.fedoraproject.org |

### Flow

```
┌──────────────────────────────────────────────────────────────────┐
│ 1. IoT COMPOSE (compose-iot01.rdu3.fedoraproject.org)            │
│    Trigger: Daily cron                                           │
│    Script: pungi-iot/nightly.sh                                  │
│    Config: pungi-iot/fedora-iot.conf                             │
│    Treefile: base-images/fedora-rawhide.yaml                     │
│                                                                  │
│    Output: /mnt/koji/compose/iot/<compose-id>/compose/           │
│            └── <arch>/images/Fedora-base-bootc-<ver>.ociarchive  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (fedora-messaging)
┌──────────────────────────────────────────────────────────────────┐
│ 2. CLOUD-IMAGE-UPLOADER (OpenShift)                              │
│                                                                  │
│    Listens: org.fedoraproject.prod.pungi.compose.status.change   │
│    Maps: subvariant "base" → repository "fedora-bootc"           │
│    Pushes via skopeo to configured registries                    │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ 3. CONTAINER REGISTRIES                                          │
│                                                                  │
│    - quay.io/fedora/fedora-bootc                                 │
│    - registry.fedoraproject.org/fedora-bootc                     │
└──────────────────────────────────────────────────────────────────┘
```

### Key Configuration Files

#### 1. Compose: Image Build Definition

**File:** `pungi-iot/fedora-iot.conf` (lines 276-300)

```python
ostree_container = {
    "^IoT$": [
        {
            "config_url": "https://pagure.io/fedora-iot/base-images",
            "config_branch": "main",
            "treefile": "fedora-rawhide.yaml",
            "arches": ["x86_64", "aarch64", "ppc64le", "s390x"],
            "subvariant": "base",           # <-- Used for mapping
            "name": "Fedora-base-bootc",
        },
    ]
}
```

#### 2. Uploader: Subvariant to Repository Mapping

**File:** `ansible/roles/openshift-apps/cloud-image-uploader/templates/config.toml`

```toml
[consumer_config.container.repos]
base = "fedora-bootc"    # subvariant "base" → repo "fedora-bootc"
IoT = "fedora-iot"
```

#### 3. Uploader: Target Registries

**File:** `ansible/roles/openshift-apps/cloud-image-uploader/templates/config.toml`

```toml
[[consumer_config.container.registries]]
url = "registry.fedoraproject.org"

[[consumer_config.container.registries]]
url = "quay.io/fedora"
```

### Tags Applied

| Compose Type | Tags |
|--------------|------|
| Rawhide | `<version>`, `rawhide` |
| Current Stable | `<version>`, `latest` |
| Branched | `<version>` |

### Common Changes (Production)

| Task | Where to Change |
|------|-----------------|
| Add/remove packages from image | `base-images/` repo (manifest YAML files) |
| Change architectures | `pungi-iot/fedora-iot.conf` → `ostree_container.arches` |
| Add new registry | `ansible/.../cloud-image-uploader/templates/config.toml` → `registries` |
| Change repository name | `ansible/.../cloud-image-uploader/templates/config.toml` → `repos` mapping |
| Change tagging logic | `cloud-image-uploader/.../handler.py` |

---

## Part 2: Development Flow (Konflux)

### Repositories

| Repository | URL | Purpose |
|------------|-----|---------|
| compose-images | https://gitlab.com/fedora/bootc/compose-images | Generates images containing RPMs used by base-images |
| base-images | https://gitlab.com/fedora/bootc/base-images | Image definitions + Tekton build pipelines |
| tekton-catalog | https://gitlab.com/fedora/bootc/tekton-catalog | Release pipeline definitions |
| tenants-config | https://gitlab.com/fedora/infrastructure/konflux/tenants-config | Konflux tenant configuration |

### Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│ 0. COMPOSE IMAGES                                                    │
│                                                                      │
│    Source: gitlab.com/fedora/bootc/compose-images                    │
│    Output: quay.io/bootc-devel/fedora-bootc-<version>-compose        │
│                                                                      │
│    These images contain the RPM repositories used by base-images.    │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 1. BUILD (triggered by git push or Renovate)                         │
│                                                                      │
│    Source: gitlab.com/fedora/bootc/base-images                       │
│    Pipeline: .tekton/fedora-bootc-*-push.yaml                        │
│    Input: REPOS_IMAGE from compose-images                            │
│                                                                      │
│    Output: quay.io/konflux-fedora/bootc-tenant/                      │
│            fedora-bootc-<version>-<tier>:{{revision}}                │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (Konflux creates Snapshot)
┌──────────────────────────────────────────────────────────────────────┐
│ 2. RELEASE (auto-triggered by ReleasePlan)                           │
│                                                                      │
│    ReleasePlan: release-fedora-bootc-to-quay-io                      │
│    Pipeline: push-to-external-registry                               │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 3. OUTPUT                                                            │
│                                                                      │
│    quay.io/bootc-devel/fedora-bootc-<version>-standard               │
│    quay.io/bootc-devel/fedora-bootc-<version>-minimal                │
│    quay.io/bootc-devel/fedora-bootc-<version>-minimal-plus           │
│    quay.io/bootc-devel/fedora-bootc-<version>-iot                    │
└──────────────────────────────────────────────────────────────────────┘
```

### Image Tiers

See the [README](README.md) for details on the different image tiers (minimal, minimal-plus, standard, iot).

### Renovate Automation

Renovate automatically updates dependencies. See the description comments in [renovate.json](renovate.json) for scheduling and configuration details.

### Common Changes (Development)

| Task | Where to Change |
|------|-----------------|
| Add new component | `tenants-config/.../components/` |
| Change destination registry | `tenants-config/.../releaseplans/release-to-quay-io/` |
| Modify release pipeline | `tekton-catalog/pipelines/push-to-external-registry/` |
| Add new Fedora version | See [Adding a New Fedora Version](#adding-a-new-fedora-version-to-konflux) |
| Remove EOL Fedora version | See [Removing an EOL Fedora Version](#removing-an-eol-fedora-version-from-konflux) |

---

## Part 3: Managing Fedora Versions in Konflux

This section describes how to add a new Fedora version or remove an EOL version from Konflux.

**Example scenario:** Fedora 42 is going EOL and needs to be removed. Rawhide (F45) is branching, so we need to add Fedora 44 as the new branched release.

### Adding a New Fedora Version to Konflux

#### Step 1: Add Release to compose-images Repo

**Repository:** https://gitlab.com/fedora/bootc/compose-images

Add the new release definition so that compose images are generated for the new version. This must be done first as base-images depends on these compose images.

1. Create new Tekton pipelines in `.tekton/` for the new version (copy from existing version)
2. Update `RELEASEVER`, `COMPOSE_BRANCHED`, and labels in the new pipelines
3. Add a package rule for the new version in `renovate.json`

See [MR !187](https://gitlab.com/fedora/bootc/compose-images/-/merge_requests/187) for reference (F44 addition).

#### Step 2: Create Tekton Pipelines (base-images repo)

**Repository:** https://gitlab.com/fedora/bootc/base-images

Copy the current release pipelines to the new version and update rawhide for the next version.

See the code snippets used for F44 in [MR !363 comment](https://gitlab.com/fedora/bootc/base-images/-/merge_requests/363#note_3071603283) for reference.

#### Step 3: Update Renovate Configuration (base-images repo)

Add package rules for the new version in `renovate.json`. See the existing rules for other versions as a template.

#### Step 4: Create Tenant Configuration (tenants-config repo)

**Repository:** https://gitlab.com/fedora/infrastructure/konflux/tenants-config

```bash
cd clusters/kflux-fedora-01/tenants/bootc-tenant/applications/fedora-bootc/
NEW_RELEASE=44

# Copy from rawhide
cp -r rawhide $NEW_RELEASE

# Update version references
sed -i "s/compose-rawhide-id/compose-branched-id/" $NEW_RELEASE/releaseplans/release-to-quay-io/kustomization.yaml
find "${NEW_RELEASE}/" -type f | xargs sed -i "s/rawhide/$NEW_RELEASE/g"
```


Add the new version to `fedora-bootc/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - "rawhide"
  - "44"      # <-- Add new version
  - "43"
  - "42"
```

See [MR !237](https://gitlab.com/fedora/infrastructure/konflux/tenants-config/-/merge_requests/237) for reference (F45 addition).

### Removing an EOL Fedora Version from Konflux

When a Fedora version reaches EOL (e.g., F42), follow these steps:

#### Step 1: Remove Tekton Pipelines (base-images repo)

**Repository:** https://gitlab.com/fedora/bootc/base-images

```bash
cd .tekton/
git rm fedora-bootc-42-*.yaml
```

#### Step 2: Remove Renovate Rules (base-images repo)

Remove the package rules for F42 from `renovate.json` (the two blocks matching `fedora-bootc-42-*`).

#### Step 3: Remove Tenant Configuration (tenants-config repo)

**Repository:** https://gitlab.com/fedora/infrastructure/konflux/tenants-config

Remove the version from `fedora-bootc/kustomization.yaml` and delete the directory:

```bash
cd cluster/kfluxfedorap01/bootc-tenant/applications/fedora-bootc/

# Edit kustomization.yaml to remove "42" from resources

# Delete the version directory
rm -rf 42/
```

#### Step 4: Remove from compose-images Repo

**Repository:** https://gitlab.com/fedora/bootc/compose-images

Remove the EOL release pipelines and renovate rules:

```bash
cd .tekton/
git rm fedora-bootc-42-compose-*.yaml
```

Also remove the package rule for F42 from `renovate.json` (the block matching `fedora-42-.*-compose`).
