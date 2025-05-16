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
  description = "Email del Service Account per lo sniffer."
  value       = google_service_account.sniffer_sa.email
}

output "cloud_run_service_account_email" {
  description = "Email del Service Account per Cloud Run."
  value       = google_service_account.cloud_run_sa.email
}

output "test_generator_vm_ip" {
  description = "IP esterno della VM di test."
  value       = module.test_generator_vm.vm_external_ip
}

output "test_generator_vm_name" {
  description = "Nome della VM di test."
  value       = module.test_generator_vm.vm_name
}

# --- NUOVO OUTPUT CON ISTRUZIONI ---
output "test_vm_sniffer_setup_instructions" {
  description = "Istruzioni per configurare e avviare lo sniffer sulla VM di test."
  value = <<EOT
ISTRUZIONI PER LO SNIFFER SULLA VM DI TEST ('${module.test_generator_vm.vm_name}'):

1. PREPARAZIONE CHIAVE SERVICE ACCOUNT DELLO SNIFFER:
   Sulla TUA MACCHINA LOCALE, esegui questo comando per generare la chiave per '${google_service_account.sniffer_sa.email}':
     gcloud iam service-accounts keys create ./sniffer-key.json --iam-account=${google_service_account.sniffer_sa.email}
   Questo creerà un file 'sniffer-key.json' nella tua directory corrente.

2. ACCEDI ALLA VM DI TEST VIA SSH:
     gcloud compute ssh --project ${var.gcp_project_id} --zone ${module.test_generator_vm.vm_zone} ${module.test_generator_vm.vm_name}

3. PREPARA LA DIRECTORY PER LA CHIAVE SULLA VM:
   Una volta connesso alla VM, esegui:
     mkdir -p ~/my-sniffer-key

4. COPIA LA CHIAVE SULLA VM:
   Apri un NUOVO terminale sulla TUA MACCHINA LOCALE (non quello della sessione SSH) e esegui:
     gcloud compute scp ./sniffer-key.json ${module.test_generator_vm.vm_name}:~/my-sniffer-key/key.json --project ${var.gcp_project_id} --zone ${module.test_generator_vm.vm_zone}

5. MODIFICA DOCKER-COMPOSE.YML SULLA VM:
   Torna alla sessione SSH sulla VM. Lo script di startup ha preparato i file in /opt/sniffer.
   Modifica il file docker-compose.yml per puntare alla chiave che hai appena copiato:
     sudo nano /opt/sniffer/docker-compose.yml
   Trova la sezione 'volumes:' e cambia la riga:
     - "/path/to/local/gcp-key-dir:/app/gcp-key:ro"
   in:
     - "$HOME/my-sniffer-key:/app/gcp-key:ro"
   Salva il file (Ctrl+O, Invio, Ctrl+X se usi nano).

6. AVVIA LO SNIFFER:
   Sempre sulla VM:
     cd /opt/sniffer
     sudo docker-compose up -d

7. CONTROLLA I LOG DELLO SNIFFER:
     sudo docker logs onprem-sniffer-instance -f

8. GENERA TRAFFICO DI RETE SULLA VM PER TESTARE:
     ping -c 20 google.com
     curl http://example.com

9. PER FERMARE LO SNIFFER:
     cd /opt/sniffer
     sudo docker-compose down
EOT
}