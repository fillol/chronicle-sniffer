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
    email  = var.attached_service_account_email
    scopes = var.access_scopes
  }

  metadata = {
    VM_SNIFFER_IMAGE_URI       = var.sniffer_image_uri_val
    VM_SNIFFER_GCP_PROJECT_ID  = var.sniffer_gcp_project_id_val
    VM_SNIFFER_INCOMING_BUCKET = var.sniffer_incoming_bucket_val
    VM_SNIFFER_PUBSUB_TOPIC_ID = var.sniffer_pubsub_topic_id_val
    VM_SNIFFER_ID              = var.sniffer_id_val # Passa lo SNIFFER_ID
  }

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
  target_tags   = [var.vm_name]
  source_ranges = var.ssh_source_ranges
}