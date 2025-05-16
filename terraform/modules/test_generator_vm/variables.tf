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
  default     = "e2-micro"
}

variable "vm_image" {
  description = "Immagine disco per la VM."
  type        = string
  default     = "debian-cloud/debian-11"
}

variable "service_account_email" {
  description = "Email del Service Account per la VM (null per usare il default GCE SA)."
  type        = string
  default     = null # Useremo il GCE default SA
}

variable "disk_type" {
  description = "Tipo di disco per la VM (es. pd-standard, pd-ssd)."
  type        = string
  default     = "pd-standard"
}

variable "startup_script" {
  description = "Script di avvio per la VM. Sarà sovrascritto nel main.tf del modulo."
  type        = string
  default     = "#!/bin/bash\necho 'Default startup script, dovrebbe essere sovrascritto.'"
}

variable "ssh_source_ranges" {
  description = "Lista di CIDR IP permessi per SSH."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "access_scopes" {
  type    = list(string)
  default = [
    "https://www.googleapis.com/auth/cloud-platform", // Scope ampio per gcloud
  ]
}

// Variabili per lo sniffer sulla VM
variable "sniffer_image_to_run" {
  description = "URI completo dell'immagine Docker dello sniffer da Artifact Registry."
  type        = string
}

variable "sniffer_gcp_project_id" {
  description = "ID del progetto GCP per la configurazione dello sniffer."
  type        = string
}

variable "sniffer_incoming_bucket" {
  description = "Nome del bucket GCS per i pcap (solo nome)."
  type        = string
}

variable "sniffer_pubsub_topic_id" {
  description = "ID completo del topic Pub/Sub per le notifiche dello sniffer."
  type        = string
}