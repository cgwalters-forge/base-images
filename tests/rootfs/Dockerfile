# This should always be replaced with podman build --from.
FROM localhost/image-to-test as rootfs

FROM quay.io/centos/centos:stream10
COPY . /src
RUN --mount=type=bind,from=rootfs,target=/target-rootfs /src/run /target-rootfs
