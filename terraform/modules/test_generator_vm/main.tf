resource "google_compute_instance" "generator" {
  project      = var.project_id
  name         = var.vm_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["traffic-generator", var.vm_name] # O "sniffer-vm" se preferisci

  boot_disk {
    initialize_params {
      image = var.vm_image
      size  = 20 // Aumentato per Docker e immagini
      type  = var.disk_type
    }
  }

  network_interface {
    network = "default"
    access_config {} // Per IP esterno
  }

  service_account {
    email  = var.attached_service_account_email // Riceve l'email del SA dedicato (test_vm_sa)
    scopes = var.access_scopes                  // "cloud-platform" è sufficiente
  }

  // Metadati passati allo script di startup. 
  // Le chiavi qui (es. VM_SNIFFER_IMAGE_URI) devono corrispondere 
  // a quelle lette da get_metadata_value() nello script .sh.
  metadata = {
    VM_SNIFFER_IMAGE_URI        = var.sniffer_image_uri_val
    VM_SNIFFER_GCP_PROJECT_ID   = var.sniffer_gcp_project_id_val
    VM_SNIFFER_INCOMING_BUCKET  = var.sniffer_incoming_bucket_val
    VM_SNIFFER_PUBSUB_TOPIC_ID  = var.sniffer_pubsub_topic_id_val
  }

  // Carica lo script di startup da un file esterno
  metadata_startup_script = var.startup_script_path != "" ? file(var.startup_script_path) : null

  allow_stopping_for_update = true
}

resource "google_compute_firewall" "allow_ssh_vm" {
  project = var.project_id
  name    = "${var.vm_name}-allow-ssh" 
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  target_tags   = [var.vm_name] // Applica solo a questa VM
  source_ranges = var.ssh_source_ranges
}