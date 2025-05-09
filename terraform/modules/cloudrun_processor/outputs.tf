output "service_name" {
  description = "Nome del servizio Cloud Run creato."
  value       = google_cloud_run_v2_service.processor.name
}

output "service_location" {
  description = "Location del servizio Cloud Run creato."
  value       = google_cloud_run_v2_service.processor.location
}

output "service_url" {
  description = "URL HTTPS del servizio Cloud Run."
  value       = google_cloud_run_v2_service.processor.uri
}