# terraform/modules/gcs_buckets/main.tf

resource "google_storage_bucket" "incoming_pcaps" {
  project       = var.project_id # Assicurati che il project ID sia passato o inferito correttamente
  name          = var.incoming_pcap_bucket_name
  location      = var.location
  force_destroy = false # Imposta a true solo per test se necessario

  uniform_bucket_level_access = true

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 30 # Elimina pcap dopo 30 giorni (configurabile)
    }
  }
}

resource "google_storage_bucket" "processed_udm" {
  project       = var.project_id # Assicurati che il project ID sia passato o inferito correttamente
  name          = var.processed_udm_bucket_name
  location      = var.location
  force_destroy = false

  uniform_bucket_level_access = true
}
