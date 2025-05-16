#!/bin/bash
set -e 
set -o pipefail
# Il logging su stdout/stderr da startup script viene catturato da Google Cloud Logging per l'istanza.

echo "--- VM Startup Script (External File) Iniziato ---"

# Funzione per recuperare metadati dell'istanza
get_metadata_value() {
  local key_name="$1"
  # Il server di metadati è accessibile senza autenticazione dall'interno della VM
  local value=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${key_name}")
  if [ -z "$value" ] && [ "$value" != " " ]; then # Controlla se è vuoto o solo spazi
    echo "ERRORE: Metadato '$key_name' non trovato o vuoto!" >&2
    # Considera di uscire se un metadato cruciale manca
    # exit 1 
  fi
  echo "$value"
}

echo "Recupero metadati forniti da Terraform..."
# I nomi dei metadati qui DEVONO corrispondere alle chiavi nel blocco 'metadata' 
# della risorsa 'google_compute_instance' nel modulo.
SNIFFER_IMAGE_URI_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_IMAGE_URI")
VM_GCP_PROJECT_ID_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_GCP_PROJECT_ID")
VM_INCOMING_BUCKET_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_INCOMING_BUCKET")
VM_PUBSUB_TOPIC_ID_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_PUBSUB_TOPIC_ID")

echo "Valori metadati recuperati:"
echo "  SNIFFER_IMAGE_URI: $SNIFFER_IMAGE_URI_FROM_METADATA"
echo "  GCP_PROJECT_ID:    $VM_GCP_PROJECT_ID_FROM_METADATA"
echo "  INCOMING_BUCKET:   $VM_INCOMING_BUCKET_FROM_METADATA"
echo "  PUBSUB_TOPIC_ID:   $VM_PUBSUB_TOPIC_ID_FROM_METADATA"

if [ -z "$SNIFFER_IMAGE_URI_FROM_METADATA" ] || \
   [ -z "$VM_GCP_PROJECT_ID_FROM_METADATA" ] || \
   [ -z "$VM_INCOMING_BUCKET_FROM_METADATA" ] || \
   [ -z "$VM_PUBSUB_TOPIC_ID_FROM_METADATA" ]; then
  echo "ERRORE FATALE: Uno o più metadati richiesti (SNIFFER_IMAGE_URI, VM_SNIFFER_GCP_PROJECT_ID, VM_SNIFFER_INCOMING_BUCKET, VM_SNIFFER_PUBSUB_TOPIC_ID) non sono stati recuperati. Uscita."
  exit 1
fi

echo "Installazione pacchetti necessari (curl, jq, docker, docker-compose)..."
apt-get update -y
apt-get install -y --no-install-recommends curl jq docker.io docker-compose tcpdump tcpreplay git wget

echo "Avvio e abilitazione del servizio Docker..."
systemctl start docker
systemctl enable docker

echo "Configurazione autenticazione Docker per Artifact Registry..."
# Estrae il dominio del registro dall'URI dell'immagine (es. europe-west8-docker.pkg.dev)
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
    exit 1
fi
echo "Autenticazione Docker per Artifact Registry configurata."

echo "Pull dell'immagine Docker dello sniffer da Artifact Registry: $SNIFFER_IMAGE_URI_FROM_METADATA"
if ! docker pull "$SNIFFER_IMAGE_URI_FROM_METADATA"; then
  echo "ERRORE: Fallito il pull dell'immagine Docker '$SNIFFER_IMAGE_URI_FROM_METADATA'."
  echo "Verifica che l'immagine esista in Artifact Registry e che il SA della VM abbia i permessi corretti."
  exit 1
fi
echo "Pull dell'immagine Docker dello sniffer completato."

SNIFFER_PREP_DIR="/opt/sniffer_env" # Directory sulla VM per i file di configurazione dello sniffer
SNIFFER_ENV_FILE="$SNIFFER_PREP_DIR/.env"
SNIFFER_COMPOSE_FILE="$SNIFFER_PREP_DIR/docker-compose.yml"
# Path interno al container Docker dello sniffer dove si aspetta la chiave SA
SNIFFER_GCP_KEY_CONTAINER_PATH="/app/gcp-key" 
# Path interno al container Docker dello sniffer dove si aspetta le catture
SNIFFER_CAPTURES_CONTAINER_PATH="/app/captures"

echo "Creazione directory per la configurazione dello sniffer (se non esistono): $SNIFFER_PREP_DIR"
mkdir -p "$SNIFFER_PREP_DIR"
mkdir -p "$SNIFFER_PREP_DIR/captures_host_vol" # Directory host per il volume delle catture

echo "Creazione file .env per lo sniffer in $SNIFFER_ENV_FILE"
cat << EOF_ENV > "$SNIFFER_ENV_FILE"
GCP_PROJECT_ID=$VM_GCP_PROJECT_ID_FROM_METADATA
INCOMING_BUCKET=$VM_INCOMING_BUCKET_FROM_METADATA
PUBSUB_TOPIC_ID=$VM_PUBSUB_TOPIC_ID_FROM_METADATA
GCP_KEY_FILE=$SNIFFER_GCP_KEY_CONTAINER_PATH/key.json
# ROTATE=-b filesize:5120 # Esempio, decommenta e personalizza se necessario
# INTERFACE=eth0 # Esempio, decommenta e personalizza se necessario
EOF_ENV
echo "File .env creato in $SNIFFER_ENV_FILE"

echo "Creazione file docker-compose.yml in $SNIFFER_COMPOSE_FILE"
cat << EOF_COMPOSE > "$SNIFFER_COMPOSE_FILE"
version: '3.7'
services:
  sniffer:
    image: "$SNIFFER_IMAGE_URI_FROM_METADATA" 
    container_name: onprem-sniffer-instance
    # No restart automatico, l'utente lo avvia manualmente
    env_file:
      - .env # Legge le variabili da /opt/sniffer_env/.env
    network_mode: "host"
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      # L'utente dovrà modificare questo path per puntare alla directory sulla VM
      # dove ha copiato la chiave SA dello sniffer.
      - "/path/on/vm/to/gcp-key-dir:$SNIFFER_GCP_KEY_CONTAINER_PATH:ro" # Placeholder per la chiave
      - ./captures_host_vol:$SNIFFER_CAPTURES_CONTAINER_PATH # Monta la dir per i pcap
                                                            # Questo path è relativo a CWD di docker-compose
                                                            # cioè $SNIFFER_PREP_DIR/captures_host_vol
EOF_COMPOSE
echo "File docker-compose.yml creato in $SNIFFER_COMPOSE_FILE"
    
echo "--- VM Startup Script Completato con Successo ---"
echo ""
echo "L'ambiente per lo sniffer è stato preparato in: $SNIFFER_PREP_DIR"
echo "L'immagine Docker dello sniffer è stata pullata: $SNIFFER_IMAGE_URI_FROM_METADATA"
echo ""
echo "Per le istruzioni su come avviare lo sniffer, consulta l'output 'test_vm_sniffer_setup_instructions' di Terraform."
echo "Le istruzioni includono come copiare la chiave SA dello sniffer sulla VM e modificare il docker-compose.yml."
echo "Comandi principali da eseguire sulla VM (dopo aver copiato la chiave e modificato il compose):"
echo "  cd $SNIFFER_PREP_DIR"
echo "  sudo docker-compose up -d"