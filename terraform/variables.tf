variable "gcp_project_id" {
  description = "L'ID del progetto Google Cloud."
  type        = string
}

variable "gcp_region" {
  description = "La regione GCP per le risorse principali (es. Cloud Run, Pub/Sub)."
  type        = string
  default     = "europe-west8"
}

variable "gcs_location" {
  description = "La location per i bucket GCS."
  type        = string
  default     = "EU"
}

variable "base_name" {
  description = "Prefisso per i nomi delle risorse per unicità."
  type        = string
  default     = "chronicle-sniffer"
}

variable "incoming_pcap_bucket_name" {
  description = "Nome univoco globale per il bucket GCS dei pcap in ingresso."
  type        = string
}

variable "processed_udm_bucket_name" {
  description = "Nome univoco globale per il bucket GCS dei file UDM processati."
  type        = string
}

variable "processor_cloud_run_image" {
  description = "L'URI completo dell'immagine Docker per il servizio Cloud Run Processor."
  type        = string
}

variable "sniffer_image_uri" {
  description = "L'URI completo dell'immagine Docker per lo sniffer (da Artifact Registry)."
  type        = string
}

variable "test_vm_zone" {
  description = "La zona GCP per la VM di test."
  type        = string
  default     = "europe-west8-a"
}

variable "allow_unauthenticated_invocations" {
  description = "Se true, permette invocazioni non autenticate a Cloud Run."
  type        = bool
  default     = false
}

variable "cloud_run_max_concurrency" {
  description = "Massima concorrenza per istanza Cloud Run."
  type        = number
  default     = 10 # Più plumone del default (80)
}

variable "cloud_run_cpu" {
  description = "CPU per istanza Cloud Run (es. 1000m per 1 vCPU)."
  type        = string
  default     = "1000m"
}

variable "cloud_run_memory" {
  description = "Memoria per istanza Cloud Run (es. 1Gi)."
  type        = string
  default     = "1Gi"
}

variable "ssh_source_ranges" {
  description = "Lista di CIDR IP permessi per SSH alla VM di test."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_bucket_versioning" {
  description = "Se true, abilita il versioning sui bucket GCS."
  type        = bool
  default     = false
}

variable "cmek_key_name" {
  description = "Nome della chiave KMS per la crittografia CMEK dei bucket (lasciare vuoto per usare Google-managed keys)."
  type        = string
  default     = ""
}

variable "alert_notification_channel_id" {
  description = "ID del canale di notifica di Cloud Monitoring per gli alert (es. projects/PROJECT_ID/notificationChannels/CHANNEL_ID). Creare manualmente nella console e fornire l'ID."
  type        = string
  default     = "" # Lasciare vuoto se non si configurano alert o si fa manualmente
}

variable "test_vm_sniffer_id" {
  description = "L'ID univoco per lo sniffer che girerà sulla VM di test."
  type        = string
  default     = "gce-test-sniffer"
}