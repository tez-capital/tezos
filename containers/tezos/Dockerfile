FROM docker.io/ubuntu:jammy

ARG TARGETPLATFORM
ARG ARCH

ENV TEZOS_USER=tezos \
    TEZOS_HOME=/home/tezos \
    TEZOS_BIN=/usr/local/bin \
    TEZOS_SHARE=/usr/local/share/tezos \
    REPO_API=https://api.github.com/repos/tez-capital/tezos/releases/latest

RUN apt-get update && apt-get install -y \
    curl jq libhidapi-libusb0 libsqlite3-0 libgmpxx4ldbl libpq5 libev4 \
    unzip \
    && rm -rf /var/lib/apt/lists/* && \
    apt-get clean

RUN useradd -m -d ${TEZOS_HOME} -s /bin/bash ${TEZOS_USER}

COPY scripts/docker/entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN if [ "${TARGETPLATFORM}" = "linux/amd64" ]; then \
        ARCH="x64"; \
    elif [ "${TARGETPLATFORM}" = "linux/arm64" ]; then \
        ARCH="arm64"; \
    else \
        echo "Unsupported platform: ${TARGETPLATFORM}"; exit 1; \
    fi && \
    LATEST_TAG=$(curl -s ${REPO_API} | jq -r .tag_name) && \
    DOWNLOAD_URL="https://github.com/tez-capital/tezos/releases/download/${LATEST_TAG}/octez-all-${ARCH}.zip" && \
    echo "Downloading ${DOWNLOAD_URL}" && \
    curl -L -o octez.zip ${DOWNLOAD_URL} && \
    unzip octez.zip -d ${TEZOS_BIN} && \
    rm octez.zip
RUN echo "http		80/tcp		www		# WorldWideWeb HTTP" > /etc/services

USER ${TEZOS_USER}
WORKDIR ${TEZOS_HOME}

RUN curl -o fetch-params.sh https://raw.githubusercontent.com/zcash/zcash/713fc761dd9cf4c9087c37b078bdeab98697bad2/zcutil/fetch-params.sh && \
    chmod +x fetch-params.sh && \
    ./fetch-params.sh && \
    rm fetch-params.sh

COPY ./scripts/ ${TEZOS_SHARE}/

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
