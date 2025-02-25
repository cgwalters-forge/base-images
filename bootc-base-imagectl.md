# bootc-base-imagectl

A core premise of the bootc model is that rich
control over Linux system customization can be accomplished
with a "default" container build:

```
FROM <base image>
RUN ...
```

As of recently, it is possible to e.g. swap the kernel
and other fundamental components as part of default derivation.

However, some use cases want even more control - for example,
as an organization deploying a bootc system, I may want to ensure
the base image version carries a set of packages at
exactly specific versions (perhaps defined by a lockfile,
or an rpm-md repository). There are many tools which
manage snapshots of yum (rpm-md) repositories.

There are currently issues where it won't quite work to e.g.
`dnf -y upgrade selinux-policy-targeted`.

The `/usr/libexec/bootc-base-imagectl` tool which is
included in the base image is designed to enable building
a root filesystem in ostree-container format from a set
of RPMs controlled by the user.

## Understanding the base image content

Most, but not all content from the base image comes from RPMs.
There is some additional non-RPM content, as well as postprocessing
that operates on the filesystem root. At the current time the
implementation of the base image build uses `rpm-ostree`,
but this is considered an implementation detail subject to change.

## Using bootc-base-imagectl build-rootfs

The core operation is `bootc-base-imagectl build-rootfs`.

This command takes just two arguments:

- A "source root" which should have an `/etc/yum.repos.d`
  that defines the input RPM content. This source root is also used
  to control things like the `$releasever`.
- A path to the target root filesystem which will be generated as
  a directory. The target should not already exist (but its parent must exist).

### Other options

`bootc-base-imagectl list` will enumerate available configurations that
can be selected by passing `--manifest` to `build-rootfs`.

### Implementation

The current implementation uses `rpm-ostree` on a manifest (treefile)
embedded in the container image itself. These manifests are not intended
to be editable directly. 

To emphasize: the implementation of this command (especially the configuration
files that it reads) are subject to change.

### Cross builds and the builder image

The build tooling is designed to support "cross builds"; the
repository root could e.g. be CentOS Stream 10, while the
builder root is Fedora or RHEL, etc. 

In other words, one given base image can be used as a "builder" to produce another
using different RPMs.

### Example: Generate a new image using CentOS Stream 10 content from RHEL

FROM quay.io/centos/centos:stream10 as repos

FROM registry.redhat.io/rhel10/rhel-bootc:10 as builder
RUN --mount=type=bind,from=repos,src=/,dst=/repos,rw /usr/libexec/bootc-base-imagectl build-rootfs --manifest=minimal /repos /target-rootfs

# This container image uses the "artifact pattern"; it has some
# basic configuration we expect to apply to multiple container images.
FROM quay.io/exampleos/baseconfig@sha256:.... as baseconfig

FROM scratch
COPY --from=builder /target-rootfs/ /
# Now we make other arbitrary changes. Copy our systemd units and
# other tweaks from the baseconfig container image.
COPY --from=baseconfig /usr/ /usr/
RUN <<EORUN
set -xeuo pipefail
# Install critical components
dnf -y install linux-firmware NetworkManager cloud-init cowsay
dnf clean all
bootc container lint
EORUN
LABEL containers.bootc 1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
