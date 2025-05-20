variable "project_id" {
  description = "GCP Project ID."
  type        = string
}

variable "zone" {
  description = "GCP zone for the VM."
  type        = string
}

variable "vm_name" {
  description = "Name for the sniffer/test VM."
  type        = string
  default     = "sniffer-vm-instance"
}

variable "machine_type" {
  description = "Machine type for the VM."
  type        = string
  default     = "e2-micro"
}

variable "vm_image" {
  description = "Disk image for the VM (must support Docker)."
  type        = string
  default     = "debian-cloud/debian-11" # Debian 11 is a good choice
}

variable "attached_service_account_email" {
  description = "Email of the Service Account to attach to this VM."
  type        = string
}

variable "disk_type" {
  description = "Disk type for the VM."
  type        = string
  default     = "pd-standard"
}

variable "startup_script_path" {
  description = "Path (relative to module root) to the VM's startup script file."
  type        = string
}

variable "ssh_source_ranges" {
  description = "List of CIDR IP ranges allowed for SSH access."
  type        = list(string)
}

variable "access_scopes" {
  description = "Access scopes for the VM's Service Account."
  type        = list(string)
  default     = ["https://www.googleapis.com/auth/cloud-platform"] # Broad access, common for GCE
}

variable "sniffer_image_uri_val" {
  description = "Full Docker image URI for the sniffer (e.g., from Docker Hub or Artifact Registry)."
  type        = string
}

variable "sniffer_gcp_project_id_val" {
  description = "GCP Project ID to be used by the sniffer script running on the VM."
  type        = string
}

variable "sniffer_incoming_bucket_val" {
  description = "Name of the GCS bucket for incoming pcaps (name only, no gs:// prefix)."
  type        = string
}

variable "sniffer_pubsub_topic_id_val" {
  description = "Full ID of the Pub/Sub topic for notifications (e.g., projects/PROJECT_ID/topics/TOPIC_NAME)."
  type        = string
}

variable "sniffer_id_val" {
  description = "Unique ID for the sniffer instance running on the VM."
  type        = string
  default     = "test-vm-sniffer" # Default sniffer ID for the test VM
}