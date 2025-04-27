# sniffer/Dockerfile - Immagine per lo Sniffer On-Premises

# Usa un'immagine base con gcloud SDK e strumenti di rete
FROM google/cloud-sdk:slim

# Installa tshark e procps (per kill)
RUN apt-get update && apt-get install -y --no-install-recommends \
    tshark \
    procps \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Crea directory di lavoro e per le catture
WORKDIR /app
RUN mkdir /app/captures

# Copia lo script di entrypoint
COPY sniffer_entrypoint.sh .
RUN chmod +x sniffer_entrypoint.sh

# Directory per montare la chiave SA
RUN mkdir /app/gcp-key

# Definisci il punto di ingresso
ENTRYPOINT ["/app/sniffer_entrypoint.sh"]

# Nota: La chiave SA (sniffer-key.json) deve essere montata in /app/gcp-key/key.json
# tramite un volume Docker al momento dell'esecuzione.
