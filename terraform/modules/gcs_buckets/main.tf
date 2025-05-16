resource "google_storage_bucket" "incoming_pcaps" {
  project                     = var.project_id
  name                        = var.incoming_pcap_bucket_name
  location                    = var.location
  force_destroy               = true // siamo in fase di test, quindi possiamo perdere le catture
  uniform_bucket_level_access = true

  dynamic "versioning" {
    for_each = var.enable_versioning ? [1] : []
    content {
      enabled = true
    }
  }

  dynamic "encryption" {
    for_each = var.cmek_key_name != "" ? [1] : []
    content {
      default_kms_key_name = var.cmek_key_name
    }
  }

  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 30 }
  }
}

resource "google_storage_bucket" "processed_udm" {
  project                     = var.project_id
  name                        = var.processed_udm_bucket_name
  location                    = var.location
  force_destroy               = false
  uniform_bucket_level_access = true

  dynamic "versioning" {
    for_each = var.enable_versioning ? [1] : []
    content {
      enabled = true
    }
  }

  dynamic "encryption" {
    for_each = var.cmek_key_name != "" ? [1] : []
    content {
      default_kms_key_name = var.cmek_key_name
    }
  }
}