FROM google/cloud-sdk:slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    tshark \
    procps \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mkdir /app/captures

COPY sniffer_entrypoint.sh .
RUN chmod +x sniffer_entrypoint.sh

# Directory per montare la chiave SA
RUN mkdir /app/gcp-key

ENTRYPOINT ["/app/sniffer_entrypoint.sh"]