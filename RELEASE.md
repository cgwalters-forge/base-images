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
| base-images | https://gitlab.com/fedora/bootc/base-images | Image definitions + Tekton build pipelines |
| tekton-catalog | https://gitlab.com/fedora/bootc/tekton-catalog | Release pipeline definitions |
| tenants-config | https://gitlab.com/fedora/infrastructure/konflux/tenants-config | Konflux tenant configuration |

### Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1. BUILD (triggered by git push or Renovate)                         │
│                                                                      │
│    Source: gitlab.com/fedora/bootc/base-images                       │
│    Pipeline: .tekton/fedora-bootc-*-push.yaml                        │
│                                                                      │
│    Output: quay.io/konflux-fedora/bootc-tenant/                      │
│            fedora-bootc-rawhide-standard:{{revision}}                │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (Konflux creates Snapshot)
┌──────────────────────────────────────────────────────────────────────┐
│ 2. RELEASE (auto-triggered by ReleasePlan)                           │
│                                                                      │
│    ReleasePlan: release-fedora-bootc-to-quay-io                      │
│    Pipeline: push-to-external-registry                               │
│                                                                      │
│    Steps:                                                            │
│    - verify-access-to-resources                                      │
│    - apply-mapping (source → destination repos)                      │
│    - verify-conforma (Enterprise Contract policy check)              │
│    - push-snapshot (skopeo copy to target registry)                  │
│    - make-repo-public                                                │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 3. OUTPUT                                                            │
│                                                                      │
│    quay.io/bootc-devel/fedora-bootc-rawhide-standard                 │
│    quay.io/bootc-devel/fedora-bootc-rawhide-minimal                  │
│    quay.io/bootc-devel/fedora-bootc-rawhide-minimal-plus             │
│    quay.io/bootc-devel/fedora-bootc-rawhide-iot                      │
│    quay.io/bootc-devel/fedora-bootc-rawhide-compose                  │
└──────────────────────────────────────────────────────────────────────┘
```

### Image Tiers

| Tier | Description | Inherits From |
|------|-------------|---------------|
| `minimal` | Minimal bootable base | - |
| `minimal-plus` | Shared base for Fedora image-based variants | minimal |
| `standard` | Full generic base image | minimal-plus |
| `iot` | IoT-specific variant | minimal-plus |

### Renovate Automation

| Dependency | Schedule | Purpose |
|------------|----------|---------|
| `REPOS_IMAGE` | At any time | Updates compose image reference |
| `bootc-pipeline` | 2-5 AM UTC daily | Updates Tekton pipeline |

Both are auto-merged when tests pass.

### Key Configuration Files

#### 1. Build Pipeline

**File:** `base-images/.tekton/fedora-bootc-rawhide-standard-push.yaml`

```yaml
params:
  - name: build-args
    value:
      - REPOS_IMAGE=quay.io/bootc-devel/fedora-bootc-rawhide-compose:...
      - MANIFEST=fedora-standard
  - name: output-image
    value: quay.io/konflux-fedora/bootc-tenant/fedora-bootc-rawhide-standard:{{revision}}
```

#### 2. ReleasePlan (promotion mapping)

**File:** `tenants-config/cluster/kfluxfedorap01/bootc-tenant/applications/fedora-bootc/rawhide/releaseplans/release-to-quay-io/kustomization.yaml`

```yaml
- op: replace
  path: /spec/data/mapping/components
  value:
    - name: fedora-bootc-rawhide-standard
      repository: quay.io/bootc-devel/fedora-bootc-rawhide-standard
    - name: fedora-bootc-rawhide-minimal
      repository: quay.io/bootc-devel/fedora-bootc-rawhide-minimal
    # ...
```

#### 3. Release Pipeline

**File:** `tekton-catalog/pipelines/push-to-external-registry/push-to-external-registry.yaml`

### Common Changes (Development)

| Task | Where to Change |
|------|-----------------|
| Add new component | `tenants-config/.../components/` |
| Change destination registry | `tenants-config/.../releaseplans/release-to-quay-io/` |
| Modify release pipeline | `tekton-catalog/pipelines/push-to-external-registry/` |
| Add new Fedora version | Create new version directory under `tenants-config/.../fedora-bootc/` |

---
