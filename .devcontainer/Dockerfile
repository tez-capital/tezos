FROM docker.io/ocaml/opam:alpine-ocaml-4.14
# FROM docker.io/ocaml/opam:debian-ocaml-4.14

USER root

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC
ENV BLST_PORTABLE=true

# Build blst used by ocaml-bls12-381 without ADX to support old CPU
# architectures.
# See https://gitlab.com/tezos/tezos/-/issues/1788 and
# https://gitlab.com/dannywillems/ocaml-bls12-381/-/merge_requests/135/
ENV BLST_PORTABLE=true

# we trust sw distributors
# We install sccache as a static binary because at the moment of writing
# the package sccache is not available on ubuntu jammy
#hadolint ignore=DL3008,DL3009
RUN apk add bubblewrap eudev-dev libusb-dev \
      rsync git m4 build-base \
      patch unzip curl wget ca-certificates \
      opam jq bc cargo sqlite-static \
      autoconf cmake libev-dev \
      libffi-dev gmp-dev \
      hidapi-dev rust \
      zlib-dev zlib-static \
      protobuf-dev protoc \
      sqlite-dev libpq-dev \
      bash-completion debian-devscripts && \
    ARCH=$(uname -m) && \
    curl  -L --output sccache.tgz "https://github.com/mozilla/sccache/releases/download/v0.8.1/sccache-v0.8.1-$ARCH-unknown-linux-musl.tar.gz" && \
    tar zxvf sccache.tgz && \
    cp "sccache-v0.8.1-$ARCH-unknown-linux-musl/sccache" /usr/local/bin/sccache && \
    rm -Rf sccache*

COPY scripts/version.sh /root/tezos/scripts/

RUN opam init --bare --disable-sandboxing

# we do not need everything to run build-deps
# we copy the mininum amount of files to use
# the caching mechanism more efficiently
COPY scripts/install_build_deps.sh /root/tezos/scripts/
COPY scripts/install_build_deps.rust.sh /root/tezos/scripts/
COPY scripts/install_dal_trusted_setup.sh /root/tezos/scripts/
COPY Makefile /root/tezos/
COPY opam/virtual/octez-deps.opam.locked /root/tezos/opam/virtual/
COPY opam /root/tezos/

WORKDIR /root/tezos

# we download and copy the zcash params in a separate directory
# and before the make build-deps to create a second docker layer and
# optimize caching
RUN DAL_TRUSTED_SETUP="/root/tezos/dal-trusted-setup" \
    scripts/install_dal_trusted_setup.sh

#hadolint ignore=SC2154, SC1091
# RUN . ./scripts/version.sh && \
#     eval $(opam env) && \
#     . ~/.cargo/env && \
#     make build-deps && \
#     mv dal-trusted-setup _opam/share/dal-trusted-setup
