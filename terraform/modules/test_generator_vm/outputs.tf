output "vm_name" {
  description = "Nome della VM creata."
  value       = google_compute_instance.generator.name
}

output "vm_zone" {
    description = "Zona della VM creata."
    value       = google_compute_instance.generator.zone
}

output "vm_internal_ip" {
  description = "IP interno della VM."
  value       = google_compute_instance.generator.network_interface[0].network_ip
}

output "vm_external_ip" {
  description = "IP esterno della VM (se disponibile)."
  # Usa l'operatore splat [*] e l'indice [0] per gestire il caso in cui non ci sia IP esterno
  value       = try(google_compute_instance.generator.network_interface[0].access_config[0].nat_ip, "N/A")
}

output "ssh_command" {
    description = "Comando gcloud suggerito per connettersi via SSH alla VM."
    value       = "gcloud compute ssh --project ${var.project_id} --zone ${google_compute_instance.generator.zone} ${google_compute_instance.generator.name}"
}