FROM docker.io/ubuntu:jammy

ARG ARCH

ENV TEZOS_USER=tezos \
    TEZOS_HOME=/home/tezos \
    TEZOS_BIN=/usr/local/bin \
    TEZOS_SHARE=/usr/local/share/tezos \
    REPO_API=https://api.github.com/repos/tez-capital/tezos/releases/latest

RUN apt-get update && apt-get install -y \
    curl jq \
    unzip \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -d ${TEZOS_HOME} -s /bin/bash ${TEZOS_USER}

COPY scripts/docker/entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN LATEST_TAG=$(curl -s ${REPO_API} | jq -r .tag_name) && \
    DOWNLOAD_URL="https://github.com/tez-capital/tezos/releases/download/${LATEST_TAG}/octez-all-${ARCH}.zip" && \
    echo "Downloading ${DOWNLOAD_URL}" && \
    curl -L -o octez.zip ${DOWNLOAD_URL} && \
    unzip octez.zip -d ${TEZOS_BIN} && \
    rm octez.zip

USER ${TEZOS_USER}
WORKDIR ${TEZOS_HOME}

COPY ./scripts/ ${TEZOS_SHARE}/

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
