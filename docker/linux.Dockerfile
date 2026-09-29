# Static (musl) Linux builds: run on the architecture being built.
FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8
RUN apk add --no-cache bash build-base coreutils curl diffutils linux-headers perl pkgconf tar xz bzip2
WORKDIR /build
