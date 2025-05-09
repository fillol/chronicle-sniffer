terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.1.0"
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}