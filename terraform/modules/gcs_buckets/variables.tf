variable "project_id" {
  description = "ID Progetto GCP (necessario se non inferito dal provider)."
  type        = string
  default     = null # Permette al provider di inferirlo se configurato
}

variable "location" {
  description = "Location per i bucket GCS."
  type        = string
}

variable "incoming_pcap_bucket_name" {
  description = "Nome per il bucket dei pcap in ingresso."
  type        = string
}

variable "processed_udm_bucket_name" {
  description = "Nome per il bucket dei file UDM processati."
  type        = string
}