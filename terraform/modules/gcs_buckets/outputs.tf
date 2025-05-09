output "incoming_pcap_bucket_id" {
  description = "ID (nome) del bucket per i pcap in ingresso."
  value       = google_storage_bucket.incoming_pcaps.name
}

output "processed_udm_bucket_id" {
  description = "ID (nome) del bucket per i file UDM processati."
  value       = google_storage_bucket.processed_udm.name
}