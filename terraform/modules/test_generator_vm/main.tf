resource "google_compute_instance" "generator" {
  project      = var.project_id
  name         = var.vm_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["traffic-generator", var.vm_name] # Tags for firewall rules and organization

  boot_disk {
    initialize_params {
      image = var.vm_image
      size  = 20 # GB, adjust if needed
      type  = var.disk_type
    }
  }

  network_interface {
    network = "default" # Assumes use of the default VPC network
    access_config {}    # Requests an ephemeral external IP
  }

  service_account {
    email  = var.attached_service_account_email # SA for GCP API access from the VM
    scopes = var.access_scopes                  # API scopes for the SA
  }

  metadata = {
    # Pass necessary configuration to the startup script via instance metadata
    VM_SNIFFER_IMAGE_URI       = var.sniffer_image_uri_val
    VM_SNIFFER_GCP_PROJECT_ID  = var.sniffer_gcp_project_id_val
    VM_SNIFFER_INCOMING_BUCKET = var.sniffer_incoming_bucket_val
    VM_SNIFFER_PUBSUB_TOPIC_ID = var.sniffer_pubsub_topic_id_val
    VM_SNIFFER_ID              = var.sniffer_id_val
    # No VM_SNIFFER_COMPOSE_CONTENT needed with the override strategy
  }

  # Execute the startup script on first boot
  metadata_startup_script = var.startup_script_path != "" ? file(var.startup_script_path) : null

  allow_stopping_for_update = true # Allows VM to be stopped for updates if needed
}

resource "google_compute_firewall" "allow_ssh_vm" {
  project = var.project_id
  name    = "${var.vm_name}-allow-ssh" # Firewall rule name
  network = "default"                  # Assumes use of the default VPC network

  allow {
    protocol = "tcp"
    ports    = ["22"] # Allow SSH
  }
  target_tags   = [var.vm_name]         # Apply rule to VMs with this tag
  source_ranges = var.ssh_source_ranges # Allowed source IP ranges for SSH
}