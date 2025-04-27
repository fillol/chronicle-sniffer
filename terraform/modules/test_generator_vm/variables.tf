# terraform/modules/test_generator_vm/variables.tf

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

variable "access_scopes" {
  description = "Scope di accesso per la VM."
  type        = list(string)
  default     = [
    "[https://www.googleapis.com/auth/devstorage.read_only](https://www.googleapis.com/auth/devstorage.read_only)",
    "[https://www.googleapis.com/auth/logging.write](https://www.googleapis.com/auth/logging.write)",
    "[https://www.googleapis.com/auth/monitoring.write](https://www.googleapis.com/auth/monitoring.write)",
    "[https://www.googleapis.com/auth/servicecontrol](https://www.googleapis.com/auth/servicecontrol)",
    "[https://www.googleapis.com/auth/service.management.readonly](https://www.googleapis.com/auth/service.management.readonly)",
    "[https://www.googleapis.com/auth/trace.append](https://www.googleapis.com/auth/trace.append)",
    "[https://www.googleapis.com/auth/cloud-platform](https://www.googleapis.com/auth/cloud-platform)" # Scope ampio, restringi se necessario
  ]
}
