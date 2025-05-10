variable "project_id" {
  description = "ID Progetto GCP."
  type        = string
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

variable "enable_versioning" {
  description = "Se true, abilita il versioning sui bucket."
  type        = bool
  default     = true
}

variable "cmek_key_name" {
  description = "Nome della chiave KMS per CMEK (opzionale)."
  type        = string
  default     = ""
}