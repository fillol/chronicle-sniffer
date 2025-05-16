variable "project_id" {
  description = "ID Progetto GCP."
  type        = string
}

variable "zone" {
  description = "Zona GCP per la VM."
  type        = string
}

variable "vm_name" {
  description = "Nome della VM sniffer/test."
  type        = string
  default     = "sniffer-vm-instance" // Default aggiornato
}

variable "machine_type" {
  description = "Tipo di macchina per la VM."
  type        = string
  default     = "e2-micro"
}

variable "vm_image" {
  description = "Immagine disco per la VM (deve supportare Docker)."
  type        = string
  default     = "debian-cloud/debian-11"
}

variable "attached_service_account_email" {
  description = "Email del Service Account da associare a questa VM."
  type        = string
}

variable "disk_type" {
  description = "Tipo di disco per la VM."
  type        = string
  default     = "pd-standard"
}

variable "startup_script_path" {
  description = "Percorso (relativo alla root del modulo) al file dello script di avvio per la VM."
  type        = string
  # Non c'è un default qui, deve essere fornito
}

variable "ssh_source_ranges" {
  description = "Lista di CIDR IP permessi per SSH."
  type        = list(string)
}

variable "access_scopes" {
  description = "Scope di accesso per il Service Account della VM."
  type        = list(string)
  default     = ["https://www.googleapis.com/auth/cloud-platform"] // Scope ampio per gcloud
}

// Variabili per i metadati da passare allo script di startup della VM
variable "sniffer_image_uri_val" {
  description = "URI completo dell'immagine Docker dello sniffer (da Artifact Registry)."
  type        = string
}

variable "sniffer_gcp_project_id_val" {
  description = "ID del progetto GCP da usare nello script dello sniffer."
  type        = string
}

variable "sniffer_incoming_bucket_val" {
  description = "Nome del bucket GCS per i pcap in ingresso (solo nome)."
  type        = string
}

variable "sniffer_pubsub_topic_id_val" {
  description = "ID completo del topic Pub/Sub per le notifiche."
  type        = string
}