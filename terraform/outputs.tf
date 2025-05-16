output "incoming_pcap_bucket_id" {
  description = "ID del bucket GCS per i pcap in ingresso."
  value       = module.gcs_buckets.incoming_pcap_bucket_id
}

output "processed_udm_bucket_id" {
  description = "ID del bucket GCS per i file UDM processati."
  value       = module.gcs_buckets.processed_udm_bucket_id
}

output "pubsub_topic_id" {
  description = "ID completo del topic Pub/Sub."
  value       = module.pubsub_topic.topic_id
}

output "pubsub_subscription_id" {
  description = "ID completo della sottoscrizione Pub/Sub."
  value       = google_pubsub_subscription.processor_subscription.id
}

output "processor_cloud_run_service_url" {
  description = "URL del servizio Cloud Run Processor."
  value       = module.cloudrun_processor.service_url
}

output "sniffer_service_account_email" {
  description = "Email del Service Account dedicato per lo sniffer (per la chiave)."
  value       = google_service_account.sniffer_sa.email
}

output "cloud_run_service_account_email" {
  description = "Email del Service Account per Cloud Run."
  value       = google_service_account.cloud_run_sa.email
}

output "test_vm_service_account_email" {
  description = "Email del Service Account associato alla VM di test."
  value       = google_service_account.test_vm_sa.email
}

output "test_generator_vm_ip" {
  description = "IP esterno della VM di test."
  value       = module.test_generator_vm.vm_external_ip
}

output "test_generator_vm_name" {
  description = "Nome della VM di test."
  value       = module.test_generator_vm.vm_name
}

output "generate_sniffer_key_command" {
  description = "Comando gcloud per generare la chiave JSON per il sniffer_sa (eseguire localmente)."
  value       = "gcloud iam service-accounts keys create ./sniffer-key.json --iam-account=${google_service_account.sniffer_sa.email}"
}

output "test_vm_sniffer_setup_instructions" {
  description = "Istruzioni per configurare e avviare lo sniffer sulla VM di test."
  value       = <<EOT

----------------------------------------------------------------------------------------------------
ISTRUZIONI PER LO SNIFFER SULLA VM DI TEST ('${module.test_generator_vm.vm_name}'):
----------------------------------------------------------------------------------------------------
L'ambiente base sulla VM è stato preparato (Docker installato, immagine sniffer '${var.sniffer_image_uri}' pullata).
Per eseguire lo sniffer, devi fornirgli la chiave del Service Account '${google_service_account.sniffer_sa.email}'.

    1.  PREPARAZIONE CHIAVE SERVICE ACCOUNT DELLO SNIFFER (sulla TUA MACCHINA LOCALE):
        Esegui il comando gcloud mostrato nell'output di Terraform chiamato 'generate_sniffer_key_command'.
        Questo comando creerà (o sovrascriverà) './sniffer-key.json' per il Service Account '${google_service_account.sniffer_sa.email}'.
        (Il comando sarà simile a: gcloud iam service-accounts keys create ./sniffer-key.json --iam-account=${google_service_account.sniffer_sa.email})

2.  ACCEDI ALLA VM DI TEST VIA SSH (dalla TUA MACCHINA LOCALE):
    ${module.test_generator_vm.ssh_command}

3.  PREPARA LA DIRECTORY PER LA CHIAVE SULLA VM (dentro la sessione SSH):
    mkdir -p ~/my-sniffer-key-vol

4.  COPIA LA CHIAVE SULLA VM (da un NUOVO terminale sulla TUA MACCHINA LOCALE):
    gcloud compute scp ./sniffer-key.json ${module.test_generator_vm.vm_name}:~/my-sniffer-key-vol/key.json --project ${var.gcp_project_id} --zone ${module.test_generator_vm.vm_zone}

5.  MODIFICA DOCKER-COMPOSE.YML SULLA VM (dentro la sessione SSH):
    Lo script di startup ha preparato i file in /opt/sniffer_env.
    Modifica il file docker-compose.yml per puntare alla directory della chiave:
    sudo nano /opt/sniffer_env/docker-compose.yml
    Trova la sezione 'volumes:' e cambia la riga:
      - "/path/on/vm/to/gcp-key-dir:/app/gcp-key:ro"
    in:
      - "$HOME/my-sniffer-key-vol:/app/gcp-key:ro"  # Se hai usato ~/my-sniffer-key-vol
    Salva il file (Ctrl+O, Invio, Ctrl+X se usi nano).

6.  AVVIA LO SNIFFER (dentro la sessione SSH):
    cd /opt/sniffer_env
    sudo docker-compose up -d

7.  CONTROLLA I LOG DELLO SNIFFER (dentro la sessione SSH):
    sudo docker logs onprem-sniffer-instance -f
    Dovresti vedere l'attivazione del SA '${google_service_account.sniffer_sa.email}' e l'avvio di tshark.

8.  GENERA TRAFFICO DI RETE SULLA VM PER TESTARE (dentro la sessione SSH):
    ping -c 20 google.com
    curl http://example.com

9.  VERIFICA LA PIPELINE:
    *   Nei log dello sniffer: messaggi di upload GCS e pubblicazione Pub/Sub.
    *   Bucket GCS '${module.gcs_buckets.incoming_pcap_bucket_id}': Dovrebbero apparire i file .pcap.
    *   Log di Cloud Run '${module.cloudrun_processor.service_name}': Messaggi di ricezione notifica e processamento.
    *   Bucket GCS '${module.gcs_buckets.processed_udm_bucket_id}': Dovrebbero apparire i file .udm.json.

10. PER FERMARE LO SNIFFER (dentro la sessione SSH):
    cd /opt/sniffer_env
    sudo docker-compose down

11. PER PULIRE TUTTE LE RISORSE GCP (dalla TUA MACCHINA LOCALE, directory terraform):
    terraform destroy
    (Ricorda di eliminare anche la chiave SA locale './sniffer-key.json').
----------------------------------------------------------------------------------------------------
EOT
}