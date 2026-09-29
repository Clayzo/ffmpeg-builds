# Windows x64 builds, cross-compiled with mingw-w64.
FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash binutils-mingw-w64-x86-64 bzip2 ca-certificates curl diffutils g++-mingw-w64-x86-64 gcc gcc-mingw-w64-x86-64 \
      libc6-dev make perl pkg-config tar xz-utils \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
