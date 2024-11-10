FROM docker.io/ocaml/opam:alpine-ocaml-4.14 AS builder

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
RUN apk add --no-cache openssl 
RUN apk add --no-cache bubblewrap eudev-dev libusb-dev \
      rsync git m4 build-base cargo \
      patch unzip curl wget ca-certificates \
      opam jq bc sqlite-static \
      autoconf cmake libev-dev \
      libffi-dev gmp-dev hidapi-dev \
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

RUN . /root/tezos/scripts/version.sh && \
    curl -s https://sh.rustup.rs > rustup-init.sh && \
    chmod +x rustup-init.sh && \
    ./rustup-init.sh --profile minimal \
      --default-toolchain "$recommended_rust_version" -y

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
COPY . /workspace
RUN rm -rf /workspace/_build /workspace/_opam

WORKDIR /workspace
# we download and copy the zcash params in a separate directory
# and before the make build-deps to create a second docker layer and
# optimize caching
RUN DAL_TRUSTED_SETUP="/root/tezos/dal-trusted-setup" \
    scripts/install_dal_trusted_setup.sh

#hadolint ignore=SC2154, SC1091
RUN . ./scripts/version.sh && \
    eval $(opam env) && \
    . ~/.cargo/env && \
    make build-deps

RUN eval $(opam env) && \
    mv /root/tezos/dal-trusted-setup _opam/share/dal-trusted-setup && \
    make static

# Stage 2: Final minimal image
FROM alpine:latest

ENV TEZOS_USER=tezos \
    TEZOS_HOME=/home/tezos \
    TEZOS_BIN=/usr/local/bin \
    TEZOS_SHARE=/usr/local/share/tezos \
    REPO_API=https://api.github.com/repos/tez-capital/tezos/releases/latest

COPY --from=builder /workspace/octez-* /usr/local/bin/
COPY scripts/docker/entrypoint.sh /usr/local/bin/
COPY ./scripts/ /usr/local/share/tezos/

RUN apk add --no-cache ca-certificates

RUN mv /usr/local/bin/octez-baker-PsQuebec /usr/local/bin/octez-baker-PsQ3NAxQ
RUN mv /usr/local/bin/octez-accuser-PsQuebec /usr/local/bin/octez-accuser-PsQ3NAxQ

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]