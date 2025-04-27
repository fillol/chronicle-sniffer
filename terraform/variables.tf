# terraform/variables.tf

variable "gcp_project_id" {
  description = "L'ID del tuo progetto Google Cloud."
  type        = string
}

variable "gcp_region" {
  description = "La regione GCP per le risorse principali (es. Cloud Run, Pub/Sub)."
  type        = string
  default     = "europe-west1"
}

variable "gcs_location" {
  description = "La location per i bucket GCS (può essere una regione o multi-regione)."
  type        = string
  default     = "EU" # Esempio: multi-regione Europea
}

variable "base_name" {
  description = "Prefisso per i nomi delle risorse per unicità."
  type        = string
  default     = "wireshark-udm"
}

variable "incoming_pcap_bucket_name" {
  description = "Nome univoco globale per il bucket GCS dei pcap in ingresso."
  type        = string
  # Esempio: default = "your-prefix-wireshark-incoming-pcaps"
}

variable "processed_udm_bucket_name" {
  description = "Nome univoco globale per il bucket GCS dei file UDM processati."
  type        = string
  # Esempio: default = "your-prefix-wireshark-processed-udm"
}

variable "processor_cloud_run_image" {
  description = "L'URI completo dell'immagine Docker per il servizio Cloud Run Processor (es. REGION-docker.pkg.dev/PROJECT_ID/REPO/IMAGE:TAG)."
  type        = string
  # Esempio: default = "europe-west1-docker.pkg.dev/my-gcp-project/my-repo/wireshark-processor:latest"
}

variable "test_vm_zone" {
  description = "La zona GCP per la VM di test (deve essere nella stessa regione di var.gcp_region)."
  type        = string
  default     = "europe-west1-b" # Assicurati che esista nella tua regione
}

variable "allow_unauthenticated_invocations" {
  description = "Se true, permette invocazioni non autenticate a Cloud Run (più semplice per Pub/Sub push senza OIDC, meno sicuro)."
  type        = bool
  default     = true
}
