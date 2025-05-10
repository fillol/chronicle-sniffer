resource "google_compute_instance" "generator" {
  project      = var.project_id
  name         = var.vm_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["traffic-generator", var.vm_name] # Tag per la regola firewall

  boot_disk {
    initialize_params {
      image = var.vm_image
      size  = 10
      type  = var.disk_type # Aggiunto tipo disco
    }
  }

  network_interface {
    network = "default"
    access_config {} # Per IP esterno
  }

  metadata_startup_script = var.startup_script # Usare variabile per flessibilità
  service_account {
    email  = var.service_account_email
    scopes = var.access_scopes
  }
  allow_stopping_for_update = true
}

resource "google_compute_firewall" "allow_ssh_vm" { # Nome cambiato per evitare conflitti se ne esiste una simile
  project = var.project_id
  name    = "${var.vm_name}-allow-ssh" # Nome univoco per la regola firewall
  network = "default"
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  target_tags   = [var.vm_name] # Applica solo a questa VM
  source_ranges = var.ssh_source_ranges # USA LA VARIABILE PER GLI IP PERMESSI
}