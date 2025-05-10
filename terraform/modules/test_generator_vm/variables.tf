variable "project_id" {
  description = "ID Progetto GCP."
  type        = string
}

variable "zone" {
  description = "Zona GCP per la VM (es. europe-west1-b)."
  type        = string
}

variable "vm_name" {
  description = "Nome della VM di test."
  type        = string
  default     = "traffic-generator-vm"
}

variable "machine_type" {
  description = "Tipo di macchina per la VM."
  type        = string
  default     = "e2-micro" # Tipo economico
}

variable "vm_image" {
  description = "Immagine disco per la VM."
  type        = string
  default     = "debian-cloud/debian-11" # Immagine Debian 11
}

variable "extra_packages" {
  description = "Stringa di pacchetti aggiuntivi da installare (separati da spazio)."
  type        = string
  default     = "" # Es: "iperf3 nmap"
}

variable "service_account_email" {
  description = "Email del Service Account per la VM (null per usare il default GCE SA)."
  type        = string
  default     = null
}

variable "disk_type" {
  description = "Tipo di disco per la VM (es. pd-standard, pd-ssd)."
  type        = string
  default     = "pd-standard"
}
variable "startup_script" {
  description = "Script di avvio per la VM."
  type        = string
  default     = <<-EOT
    #!/bin/bash
    apt-get update
    apt-get install -y --no-install-recommends tcpdump tcpreplay git curl wget
    echo "Startup script finished. Load pcap to /tmp/sample.pcap and run tcpreplay manually."
  EOT
}
variable "ssh_source_ranges" {
  description = "Lista di CIDR IP permessi per SSH."
  type        = list(string)
  default     = ["0.0.0.0/0"] # Default insicuro, da sovrascrivere!
}
variable "access_scopes" {
  type    = list(string)
  default = ["https://www.googleapis.com/auth/cloud-platform"]
}