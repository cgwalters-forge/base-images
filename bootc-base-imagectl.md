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

### Implementation

The current implementation uses `rpm-ostree` on a manifest (treefile)
embedded in the container image itself. These manifests are not intended
to be editable directly.

To emphasize: the implementation of this command (especially the configuration
files that it reads) are subject to change.

### Choosing the bootloader

By default the target gets the bootloader managed by
[bootupd](https://github.com/coreos/bootupd): shim and grub2 on
most architectures; `--bootloader=bootupd:grub+shim` asks for that
explicitly. `--bootloader=systemd-boot` installs systemd-boot instead,
and leaves out bootupd, shim, grub2 and efibootmgr:

```
/usr/libexec/bootc-base-imagectl build-rootfs --manifest=standard --bootloader=systemd-boot /target-rootfs
```

This is meant for sealed images, which boot a signed Unified Kernel
Image (UKI) with systemd-boot. Note:

- It is supported on x86_64 and aarch64 only (`bootupd:grub+shim` also
  on riscv64).
- The systemd-boot binary comes from `systemd-boot-unsigned`, so for
  Secure Boot the image build has to sign it (e.g. with `systemd-sbsign`)
  and build and sign the UKI itself; see `bootc container ukify`.
- Without bootupd, the image can only be installed with bootc's
  composefs backend. Installs with the ostree backend (including
  via bootc-image-builder and Anaconda) fail.

## Using bootc-base-imagectl rechunk

This operation is strongly related to `build-rootfs` but is also orthogonal;
it can be used on a "regular" container build as well.

This command assumes it will be run as a container image, and defaults
to wanting write access to the container storage.

```
podman run --rm --privileged -v /var/lib/containers:/var/lib/containers quay.io/fedora/fedora-bootc:rawhide \
  bootc-base-imagectl rechunk quay.io/exampleos/exampleos:build quay.io/exampleos/exampleos:latest
```

### Rationale

When performing a complex container derivation, there are several issues:

#### Replaced duplicate content

When e.g. upgrading or replacing the kernel or other large packages
as part of a container build (without squashing all layers) then
the old replaced content will still be present.

#### Removed content still present

Similarly, `RUN dnf -y remove` etc. will still retain that removed
content in prior layers.

#### Timestamp drift

By default, many tools will use the current timestamp when writing
files. `rpm` will do this (unless `SOURCE_DATE_EPOCH` is set), and
other tools like `cp` and `curl` will as well.

This means that every build of the image will produce a new
tar stream (with new timestamps) - that will get pushed to a registry
and downloaded by clients, even if the content didn't actually change.

### What rechunk does: split reproducible chunked images

The `bootc-base-imagectl rechunk` command fixes all of these issues
by taking an input container, operates on its final merged filesystem
tree (hence removed/overridden files are handled), and then splits it up
(currently based on the RPM database) into separate layers (tarballs).

Further, because bootc uses OSTree today, and OSTree canonializes all timestamps
to zero on the client side, this tool does that at build time.

### Using chunkah instead of rpm-ostree

The `--chunkah` flag switches rechunk to use [chunkah] instead of
rpm-ostree for layer splitting. In this mode, chunkah reads the rootfs
from `/chunkah` (its default) and writes an OCI archive to stdout.
The `from_image` and `to_image` positional arguments are not used.
The `--max-layers` option is respected and passed through to chunkah.

This mode automatically passes `--prune /sysroot/` to strip OSTree data
and `--label ostree.commit-` / `--label ostree.final-diffid-` to remove
OSTree-specific labels. In other words, this produces plain OCI bootc images
without any OSTree content.

To rechunk an existing image using chunkah:

```
IMG=quay.io/exampleos/exampleos:latest
podman run --rm --mount=type=image,src=$IMG,dest=/chunkah \
  -e CHUNKAH_CONFIG_STR="$(podman inspect $IMG)" \
  quay.io/fedora/fedora-bootc:rawhide \
  /usr/libexec/bootc-base-imagectl rechunk --chunkah | podman load
```

The `CHUNKAH_CONFIG_STR` environment variable passes the original
image's metadata (labels, environment, command, etc.) to chunkah so
that it is retained in the rechunked output.

[chunkah]: https://github.com/coreos/chunkah

### Other options

`bootc-base-imagectl list` will enumerate available configurations that
can be selected by passing `--manifest` to `build-rootfs`.

### Implementation

The default rechunking implementation also uses `rpm-ostree`. The `--chunkah`
mode uses [chunkah] instead, which is content-agnostic and not tied to
rpm-ostree.

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
