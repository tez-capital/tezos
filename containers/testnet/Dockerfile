FROM ghcr.io/tez-capital/tezos:latest as base

FROM docker.io/tezos/tezos:octez-v21.0-rc3

COPY --from=base /usr/local/bin/octez-* /usr/local/bin/