resource "google_compute_instance" "generator" {
  project      = var.project_id
  name         = var.vm_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["traffic-generator", var.vm_name]

  boot_disk {
    initialize_params {
      image = var.vm_image
      size  = 20
      type  = var.disk_type
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  service_account {
    email  = var.service_account_email # Ora riceverà l'email del SA dedicato (test_vm_sa)
    scopes = var.access_scopes         # "cloud-platform" è sufficiente
  }

  metadata = {
    # Le informazioni per configurare lo sniffer sono passate qui
    SNIFFER_IMAGE_URI       = var.sniffer_image_to_run
    SNIFFER_GCP_PROJECT_ID  = var.sniffer_gcp_project_id
    SNIFFER_INCOMING_BUCKET = var.sniffer_incoming_bucket
    SNIFFER_PUBSUB_TOPIC_ID = var.sniffer_pubsub_topic_id
    # Non passiamo la chiave SA dello sniffer qui, l'utente la gestirà
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -e 
    set -o pipefail
    exec > >(tee /var/log/startup-script.log|logger -t startup-script -s 2>/dev/console) 2>&1

    echo "--- VM Startup Script Iniziato ---"

    get_metadata_value() {
      curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
    }

    echo "Recupero metadati..."
    SNIFFER_IMAGE_FROM_METADATA=$(get_metadata_value "SNIFFER_IMAGE_URI")
    VM_GCP_PROJECT_ID_FROM_METADATA=$(get_metadata_value "SNIFFER_GCP_PROJECT_ID")
    VM_INCOMING_BUCKET_FROM_METADATA=$(get_metadata_value "SNIFFER_INCOMING_BUCKET")
    VM_PUBSUB_TOPIC_ID_FROM_METADATA=$(get_metadata_value "SNIFFER_PUBSUB_TOPIC_ID")

    echo "Valori metadati recuperati:"
    echo "  SNIFFER_IMAGE_FROM_METADATA: $SNIFFER_IMAGE_FROM_METADATA"
    echo "  VM_GCP_PROJECT_ID_FROM_METADATA: $VM_GCP_PROJECT_ID_FROM_METADATA"
    echo "  VM_INCOMING_BUCKET_FROM_METADATA: $VM_INCOMING_BUCKET_FROM_METADATA"
    echo "  VM_PUBSUB_TOPIC_ID_FROM_METADATA: $VM_PUBSUB_TOPIC_ID_FROM_METADATA"
    
    if [ -z "$SNIFFER_IMAGE_FROM_METADATA" ] || [ -z "$VM_GCP_PROJECT_ID_FROM_METADATA" ] || [ -z "$VM_INCOMING_BUCKET_FROM_METADATA" ] || [ -z "$VM_PUBSUB_TOPIC_ID_FROM_METADATA" ]; then
      echo "ERRORE: Una o più variabili dai metadati non sono impostate o non sono state recuperate correttamente!"
      exit 1
    fi

    echo "Installazione pacchetti necessari (curl, jq, docker)..."
    apt-get update
    apt-get install -y --no-install-recommends curl jq docker.io docker-compose tcpdump tcpreplay git wget

    echo "Avvio e abilitazione Docker..."
    systemctl start docker
    systemctl enable docker

    echo "Configurazione Docker per Artifact Registry..."
    ARTIFACT_REGISTRY_DOMAIN=$(echo $SNIFFER_IMAGE_FROM_METADATA | cut -d'/' -f1)
    if [[ -z "$ARTIFACT_REGISTRY_DOMAIN" ]]; then
        echo "ERRORE: Impossibile estrarre il dominio di Artifact Registry da $SNIFFER_IMAGE_FROM_METADATA"
        exit 1
    fi
    echo "Dominio Artifact Registry rilevato: $ARTIFACT_REGISTRY_DOMAIN"
    # Questo comando usa il SA associato alla VM. 
    # Quel SA (test_vm_sa) ha ora 'roles/artifactregistry.reader' grazie a Terraform.
    if ! gcloud auth configure-docker $ARTIFACT_REGISTRY_DOMAIN -q; then
        echo "ERRORE: Fallita la configurazione di Docker per Artifact Registry."
        gcloud auth list # Mostra l'account attivo sulla VM
        exit 1
    fi
    
    echo "Pull dell'immagine Docker dello sniffer da Artifact Registry: $SNIFFER_IMAGE_FROM_METADATA"
    if ! docker pull $SNIFFER_IMAGE_FROM_METADATA; then
      echo "ERRORE: Fallito il pull dell'immagine Docker $SNIFFER_IMAGE_FROM_METADATA. Controlla l'URI e i permessi del SA della VM."
      exit 1
    fi
    echo "Pull dell'immagine completato."

    SNIFFER_DIR="/opt/sniffer"
    SNIFFER_ENV_FILE="$SNIFFER_DIR/.env"
    SNIFFER_COMPOSE_FILE="$SNIFFER_DIR/docker-compose.yml"
    SNIFFER_GCP_KEY_TARGET_DIR="/app/gcp-key" 

    echo "Creazione directory per lo sniffer (se non esistono): $SNIFFER_DIR"
    mkdir -p $SNIFFER_DIR
    mkdir -p $SNIFFER_DIR/captures 

    echo "Creazione file .env per lo sniffer in $SNIFFER_ENV_FILE"
    cat << EOF_ENV > $SNIFFER_ENV_FILE
GCP_PROJECT_ID=$VM_GCP_PROJECT_ID_FROM_METADATA
INCOMING_BUCKET=$VM_INCOMING_BUCKET_FROM_METADATA
PUBSUB_TOPIC_ID=$VM_PUBSUB_TOPIC_ID_FROM_METADATA
GCP_KEY_FILE=$SNIFFER_GCP_KEY_TARGET_DIR/key.json
EOF_ENV

    echo "Creazione file docker-compose.yml in $SNIFFER_COMPOSE_FILE"
    cat << EOF_COMPOSE > $SNIFFER_COMPOSE_FILE
version: '3.7'
services:
  sniffer:
    image: $SNIFFER_IMAGE_FROM_METADATA 
    container_name: onprem-sniffer-instance
    env_file:
      - .env
    network_mode: "host"
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      # L'utente dovrà modificare questo path per puntare alla chiave SA dello sniffer
      # che ha copiato sulla VM e montato.
      - "/path/to/user/mounted/gcp-key-dir:$SNIFFER_GCP_KEY_TARGET_DIR:ro"
      - ./captures:/app/captures 
EOF_COMPOSE
    
    echo "--- VM Startup Script Completato ---"
    echo "L'ambiente per lo sniffer è stato preparato in $SNIFFER_DIR."
    echo "L'immagine Docker dello sniffer è stata pullata: $SNIFFER_IMAGE_FROM_METADATA"
    echo ""
    echo "ISTRUZIONI PER AVVIARE LO SNIFFER (dopo essersi connessi via SSH alla VM):"
    echo "1. Assicurati di avere il file della chiave del Service Account sniffer (es. sniffer-key.json) sulla tua macchina locale."
    echo "   (Terraform ha stampato un comando per generarla se non esiste: output 'generate_sniffer_key_command')"
    echo "2. Crea una directory sulla VM per la chiave, ad esempio:"
    echo "   mkdir -p ~/my-sniffer-key"
    echo "3. Copia la tua chiave 'sniffer-key.json' in quella directory sulla VM:"
    echo "   # Dalla TUA MACCHINA LOCALE, in un NUOVO terminale:"
    echo "   gcloud compute scp ./sniffer-key.json ${var.vm_name}:~/my-sniffer-key/key.json --project ${var.project_id} --zone ${var.zone}"
    echo "4. Modifica il file $SNIFFER_COMPOSE_FILE sulla VM:"
    echo "   sudo nano $SNIFFER_COMPOSE_FILE"
    echo "   Trova la sezione 'volumes:' e cambia la riga:"
    echo "     - \"/path/to/user/mounted/gcp-key-dir:$SNIFFER_GCP_KEY_TARGET_DIR:ro\""
    echo "   in (ad esempio, se hai copiato la chiave in ~/my-sniffer-key/key.json):"
    echo "     - \"\$HOME/my-sniffer-key:$SNIFFER_GCP_KEY_TARGET_DIR:ro\""
    echo "   Salva il file."
    echo "5. Avvia lo sniffer:"
    echo "   cd $SNIFFER_DIR"
    echo "   sudo docker-compose up -d"
    echo "6. Controlla i log:"
    echo "   sudo docker logs onprem-sniffer-instance -f"
    EOT

  allow_stopping_for_update = true
}

resource "google_compute_firewall" "allow_ssh_vm" {
  project = var.project_id
  name    = "${var.vm_name}-allow-ssh" # Nome univoco per la regola firewall
  network = "default"
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  target_tags   = [var.vm_name]         # Applica solo a questa VM
  source_ranges = var.ssh_source_ranges # USA LA VARIABILE PER GLI IP PERMESSI
}