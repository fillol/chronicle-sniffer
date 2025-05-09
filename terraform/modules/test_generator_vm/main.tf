resource "google_compute_instance" "generator" {
  project      = var.project_id
  name         = var.vm_name
  machine_type = var.machine_type
  zone         = var.zone

  tags = ["traffic-generator", var.vm_name]

  boot_disk {
    initialize_params {
      image = var.vm_image
      size  = 10 # GB
    }
  }

  network_interface {
    # Usa la rete di default
    network = "default"
    access_config {
      # Assegna un IP esterno per poter fare SSH
    }
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    # Update and install necessary tools
    apt-get update
    apt-get install -y --no-install-recommends tcpdump tcpreplay git curl wget ${var.extra_packages}

    echo "Startup script finished."
    # Nota: Questo script installa solo gli strumenti.
    # L'utente dovrà caricare/creare un file pcap (es. /tmp/sample.pcap)
    # e poi eseguire manualmente tcpreplay o altri comandi via SSH.
    # Esempio comando manuale:
    # sudo tcpreplay --loop=10 -i eth0 /tmp/sample.pcap
    EOF

  # Service account per permettere alla VM di interagire con altri servizi GCP se necessario
  # Usare il default compute service account o uno specifico
  service_account {
    email  = var.service_account_email # Può essere null per usare il default GCE SA
    scopes = var.access_scopes
  }

  allow_stopping_for_update = true

  lifecycle {
    ignore_changes = [metadata] # Evita ricreazione se cambia solo lo startup script
  }
}

# (Opzionale) Regola Firewall per permettere SSH (di solito già presente)
resource "google_compute_firewall" "allow_ssh" {
  project = var.project_id
  name    = "${var.vm_name}-allow-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Applica alla VM tramite tag
  target_tags = [var.vm_name]
  # Permetti SSH da qualsiasi IP (per semplicità, restringi in produzione)
  source_ranges = ["0.0.0.0/0"]
}