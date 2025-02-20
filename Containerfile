# In order to make a base image as part of a Dockerfile, this container build uses
# nested containerization, so you must build with e.g.
# podman build --security-opt=label=disable --cap-add=all --device /dev/fuse <...>

# NOTE: This container build will output a single giant layer. It is strongly recommended
# to run the "rechunker" on the output of this build, see 
# https://coreos.github.io/rpm-ostree/experimental-build-chunked-oci/

FROM quay.io/fedora/fedora:rawhide as repos

# BOOTSTRAPPING: This can be any image that has rpm-ostree and selinux-policy-targeted.
FROM quay.io/fedora/fedora:rawhide as builder
RUN dnf -y install rpm-ostree selinux-policy-targeted
ARG MANIFEST=fedora-bootc.yaml
# The input git repository has .repo files committed to git rpm-ostree has historically
# emphasized that.  But here, we are fetching the repos from the container base image.
# So copy the source, and delete the hardcoded ones in git, and use the container base
# image ones.  We can drop the ones commited to git when we hard switch to Containerfile.
COPY . /src
WORKDIR /src
RUN rm -vf /src/*.repo
RUN --mount=type=cache,target=/workdir \
    --mount=type=bind,rw,from=repos,src=/,dst=/repos \
    rpm-ostree experimental compose rootfs --cachedir=/workdir --source-root-rw=/repos ${MANIFEST} /target-rootfs

# This pulls in the rootfs generated in the previous step
FROM scratch
COPY --from=builder /target-rootfs/ /
LABEL containers.bootc 1
# This is an ad-hoc way for us to reference bootc-image-builder in
# a way that in theory client tooling can inspect and find. Today
# it isn't widely used.
LABEL bootc.diskimage-builder quay.io/centos-bootc/bootc-image-builder
# https://pagure.io/fedora-kiwi-descriptions/pull-request/52
ENV container=oci
# Make systemd the default
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
