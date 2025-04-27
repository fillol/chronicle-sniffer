# terraform/modules/cloudrun_processor/variables.tf

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

# variable "service_account_email" {
#   description = "Email del Service Account da associare al servizio."
#   type        = string
#   # Non usato direttamente qui, ma passato dal main.tf se necessario altrove
# }
