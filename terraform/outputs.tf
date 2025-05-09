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
  description = "IP esterno della VM di test (se ne ha uno)."
  value       = module.test_generator_vm.vm_external_ip
}

output "test_generator_vm_name" {
  description = "Nome della VM di test."
  value       = module.test_generator_vm.vm_name
}

output "generate_sniffer_key_command" {
  description = "Comando gcloud per generare la chiave JSON per lo sniffer SA."
  value       = "gcloud iam service-accounts keys create sniffer-key.json --iam-account=${google_service_account.sniffer_sa.email}"
}