#!/bin/bash
set -e
set -o pipefail
# Il logging su stdout/stderr da startup script viene catturato da Google Cloud Logging per l'istanza.

echo "--- VM Startup Script (External File) Iniziato ---"

# Funzione per recuperare metadati dell'istanza
get_metadata_value() {
  local key_name="$1"
  local value=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${key_name}")
  if [ -z "$value" ] && [ "$value" != " " ]; then
    echo "ERRORE: Metadato '$key_name' non trovato o vuoto!" >&2
  fi
  echo "$value"
}

echo "Recupero metadati forniti da Terraform..."
SNIFFER_IMAGE_URI_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_IMAGE_URI")
VM_GCP_PROJECT_ID_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_GCP_PROJECT_ID")
VM_INCOMING_BUCKET_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_INCOMING_BUCKET")
VM_PUBSUB_TOPIC_ID_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_PUBSUB_TOPIC_ID")
VM_SNIFFER_ID_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_ID")


echo "Valori metadati recuperati:"
echo "  SNIFFER_IMAGE_URI: $SNIFFER_IMAGE_URI_FROM_METADATA"
echo "  GCP_PROJECT_ID:    $VM_GCP_PROJECT_ID_FROM_METADATA"
echo "  INCOMING_BUCKET:   $VM_INCOMING_BUCKET_FROM_METADATA"
echo "  PUBSUB_TOPIC_ID:   $VM_PUBSUB_TOPIC_ID_FROM_METADATA"
echo "  VM_SNIFFER_ID:     $VM_SNIFFER_ID_FROM_METADATA"


if [ -z "$SNIFFER_IMAGE_URI_FROM_METADATA" ] || \
   [ -z "$VM_GCP_PROJECT_ID_FROM_METADATA" ] || \
   [ -z "$VM_INCOMING_BUCKET_FROM_METADATA" ] || \
   [ -z "$VM_PUBSUB_TOPIC_ID_FROM_METADATA" ] || \
   [ -z "$VM_SNIFFER_ID_FROM_METADATA" ]; then
  echo "ERRORE FATALE: Uno o più metadati richiesti non sono stati recuperati. Uscita."
  exit 1
fi

echo "Installazione pacchetti necessari (curl, jq, docker, docker-compose, tcpdump, tcpreplay, git, wget)..."
apt-get update -y
apt-get install -y --no-install-recommends curl jq docker.io docker-compose tcpdump tcpreplay git wget

echo "Avvio e abilitazione del servizio Docker..."
systemctl start docker
systemctl enable docker

# Verifica se l'immagine dello sniffer proviene da Artifact Registry
if [[ "$SNIFFER_IMAGE_URI_FROM_METADATA" == *pkg.dev* ]]; then
  echo "L'immagine dello sniffer sembra provenire da Artifact Registry. Configurazione autenticazione Docker..."
  ARTIFACT_REGISTRY_DOMAIN=$(echo "$SNIFFER_IMAGE_URI_FROM_METADATA" | cut -d'/' -f1)
  if [[ -z "$ARTIFACT_REGISTRY_DOMAIN" ]]; then
      echo "ERRORE: Impossibile estrarre il dominio di Artifact Registry da '$SNIFFER_IMAGE_URI_FROM_METADATA'"
      exit 1
  fi
  echo "Dominio Artifact Registry rilevato: $ARTIFACT_REGISTRY_DOMAIN"
  # gcloud auth configure-docker userà il SA associato alla VM.
  # Questo SA (test_vm_sa) deve avere 'roles/artifactregistry.reader'.
  if ! gcloud auth configure-docker "$ARTIFACT_REGISTRY_DOMAIN" -q; then
      echo "ERRORE: Fallita la configurazione di Docker per Artifact Registry."
      echo "Verifica i permessi del Service Account della VM (deve avere 'roles/artifactregistry.reader')."
      echo "SA Attivo sulla VM:"
      gcloud auth list
  else
      echo "Autenticazione Docker per Artifact Registry configurata."
  fi
else
  echo "L'immagine dello sniffer non sembra provenire da Artifact Registry (es. Docker Hub). Nessuna configurazione auth Docker specifica eseguita."
fi

echo "Pull dell'immagine Docker dello sniffer: $SNIFFER_IMAGE_URI_FROM_METADATA"
if ! docker pull "$SNIFFER_IMAGE_URI_FROM_METADATA"; then
  echo "ERRORE: Fallito il pull dell'immagine Docker '$SNIFFER_IMAGE_URI_FROM_METADATA'."
  echo "Verifica che l'immagine esista, che l'URI sia corretto e che i permessi siano adeguati (se registro privato)."
  exit 1
fi
echo "Pull dell'immagine Docker dello sniffer completato."

SNIFFER_PREP_DIR="/opt/sniffer_env"
SNIFFER_ENV_FILE="$SNIFFER_PREP_DIR/.env"
SNIFFER_COMPOSE_FILE="$SNIFFER_PREP_DIR/docker-compose.yml"
SNIFFER_GCP_KEY_CONTAINER_PATH="/app/gcp-key"
SNIFFER_CAPTURES_CONTAINER_PATH="/app/captures"

echo "Creazione directory per la configurazione dello sniffer (se non esistono): $SNIFFER_PREP_DIR"
mkdir -p "$SNIFFER_PREP_DIR"
mkdir -p "$SNIFFER_PREP_DIR/captures_host_vol"

echo "Creazione file .env per lo sniffer in $SNIFFER_ENV_FILE"
cat << EOF_ENV > "$SNIFFER_ENV_FILE"
GCP_PROJECT_ID=$VM_GCP_PROJECT_ID_FROM_METADATA
INCOMING_BUCKET=$VM_INCOMING_BUCKET_FROM_METADATA
PUBSUB_TOPIC_ID=$VM_PUBSUB_TOPIC_ID_FROM_METADATA
SNIFFER_ID=${VM_SNIFFER_ID_FROM_METADATA} 
GCP_KEY_FILE=$SNIFFER_GCP_KEY_CONTAINER_PATH/key.json
# ROTATE=-b filesize:5120
# INTERFACE=eth0 # L'entrypoint dello sniffer dovrebbe auto-rilevarlo
EOF_ENV
echo "File .env creato in $SNIFFER_ENV_FILE"

echo "Creazione file docker-compose.yml in $SNIFFER_COMPOSE_FILE"
cat << EOF_COMPOSE > "$SNIFFER_COMPOSE_FILE"
version: '3.7'
services:
  sniffer:
    image: "$SNIFFER_IMAGE_URI_FROM_METADATA"
    container_name: onprem-sniffer-instance
    env_file:
      - .env
    network_mode: "host"
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - "/path/on/vm/to/gcp-key-dir:$SNIFFER_GCP_KEY_CONTAINER_PATH:ro" # Placeholder per la chiave
      - ./captures_host_vol:$SNIFFER_CAPTURES_CONTAINER_PATH
EOF_COMPOSE
echo "File docker-compose.yml creato in $SNIFFER_COMPOSE_FILE"

echo "--- VM Startup Script Completato con Successo ---"
echo ""
echo "L'ambiente per lo sniffer è stato preparato in: $SNIFFER_PREP_DIR"
echo "L'immagine Docker dello sniffer è stata pullata: $SNIFFER_IMAGE_URI_FROM_METADATA"
echo ""
echo "Per le istruzioni su come avviare lo sniffer, consulta l'output 'test_vm_sniffer_setup_instructions' di Terraform."