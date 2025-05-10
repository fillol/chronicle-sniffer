variable "project_id" {
  description = "ID Progetto GCP."
  type        = string
}

variable "region" {
  description = "Regione GCP per il servizio Cloud Run."
  type        = string
}

variable "service_name" {
  description = "Nome del servizio Cloud Run."
  type        = string
}

variable "image_uri" {
  description = "URI completo dell'immagine Docker del processore."
  type        = string
}

variable "env_vars" {
  description = "Mappa di variabili d'ambiente da passare al container."
  type        = map(string)
  default     = {}
}

variable "service_account_email" {
  description = "Email del Service Account da associare al servizio Cloud Run."
  type        = string
}

variable "max_concurrency" {
  description = "Massima concorrenza per istanza."
  type        = number
  default     = 80 # Default di Cloud Run
}

variable "cpu_limit" {
  description = "Limite CPU per istanza."
  type        = string
  default     = "1000m"
}

variable "memory_limit" {
  description = "Limite memoria per istanza."
  type        = string
  default     = "512Mi"
}