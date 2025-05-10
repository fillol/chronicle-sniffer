data "google_project" "project" { # Spostato qui per essere accessibile globalmente
  project_id = var.gcp_project_id
}

# --- Service Accounts (Creati prima per passarli ai moduli) ---
resource "google_service_account" "sniffer_sa" {
  project      = var.gcp_project_id
  account_id   = "${var.base_name}-sniffer-sa"
  display_name = "Service Account for On-Prem Sniffers"
}

resource "google_service_account" "cloud_run_sa" {
  project      = var.gcp_project_id
  account_id   = "${var.base_name}-runner-sa"
  display_name = "Service Account for Cloud Run Processor"
}

# --- Moduli ---
module "gcs_buckets" {
  source                    = "./modules/gcs_buckets"
  project_id                = var.gcp_project_id
  location                  = var.gcs_location
  incoming_pcap_bucket_name = var.incoming_pcap_bucket_name
  processed_udm_bucket_name = var.processed_udm_bucket_name
  enable_versioning         = var.enable_bucket_versioning
  cmek_key_name             = var.cmek_key_name # Passa la variabile CMEK
}

module "pubsub_topic" {
  source     = "./modules/pubsub_topic"
  project_id = var.gcp_project_id
  topic_name = "${var.base_name}-pcap-notifications"
}

module "cloudrun_processor" {
  source                = "./modules/cloudrun_processor"
  project_id            = var.gcp_project_id
  region                = var.gcp_region
  service_name          = "${var.base_name}-processor"
  image_uri             = var.processor_cloud_run_image
  service_account_email = google_service_account.cloud_run_sa.email # Passa l'email del SA
  env_vars = {
    INCOMING_BUCKET = module.gcs_buckets.incoming_pcap_bucket_id
    OUTPUT_BUCKET   = module.gcs_buckets.processed_udm_bucket_id
    GCP_PROJECT_ID  = var.gcp_project_id
    PORT            = "8080"
  }
  max_concurrency = var.cloud_run_max_concurrency
  cpu_limit       = var.cloud_run_cpu
  memory_limit    = var.cloud_run_memory
}

module "test_generator_vm" {
  source            = "./modules/test_generator_vm"
  project_id        = var.gcp_project_id
  zone              = var.test_vm_zone
  vm_name           = "${var.base_name}-test-generator"
  ssh_source_ranges = var.ssh_source_ranges # Passa i source ranges
}

# --- IAM: Sniffer Permissions ---
resource "google_pubsub_topic_iam_member" "sniffer_pubsub_publisher" {
  project = var.gcp_project_id
  topic   = module.pubsub_topic.topic_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.sniffer_sa.email}"
}

resource "google_storage_bucket_iam_member" "sniffer_gcs_writer" {
  bucket = module.gcs_buckets.incoming_pcap_bucket_id
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.sniffer_sa.email}"
}

# --- IAM: Cloud Run Processor Permissions (oltre al SA associato al servizio) ---
resource "google_storage_bucket_iam_member" "runner_gcs_writer" {
  bucket = module.gcs_buckets.processed_udm_bucket_id
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_storage_bucket_iam_member" "runner_gcs_reader" {
  bucket = module.gcs_buckets.incoming_pcap_bucket_id
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Rimossa la risorsa google_project_iam_member.runner_logging_writer
# I log standard di Cloud Run dovrebbero funzionare senza binding a livello di progetto per il SA.

# --- Cloud Run Invocation Permissions ---
resource "google_cloud_run_v2_service_iam_member" "allow_unauthenticated" {
  count      = var.allow_unauthenticated_invocations ? 1 : 0
  project    = var.gcp_project_id
  name       = module.cloudrun_processor.service_name
  location   = module.cloudrun_processor.service_location
  role       = "roles/run.invoker"
  member     = "allUsers"
  depends_on = [module.cloudrun_processor]
}

resource "google_cloud_run_v2_service_iam_member" "allow_pubsub_oidc" {
  count      = !var.allow_unauthenticated_invocations ? 1 : 0
  project    = var.gcp_project_id
  name       = module.cloudrun_processor.service_name
  location   = module.cloudrun_processor.service_location
  role       = "roles/run.invoker"
  member     = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  depends_on = [module.cloudrun_processor]
}

# --- Pub/Sub Subscription ---
resource "google_pubsub_subscription" "processor_subscription" {
  project              = var.gcp_project_id
  name                 = "${var.base_name}-processor-sub"
  topic                = module.pubsub_topic.topic_id
  ack_deadline_seconds = 600

  push_config {
    push_endpoint = module.cloudrun_processor.service_url
    dynamic "oidc_token" {
      for_each = !var.allow_unauthenticated_invocations ? [1] : []
      content {
        service_account_email = google_service_account.cloud_run_sa.email
        audience              = module.cloudrun_processor.service_url
      }
    }
  }
  depends_on = [
    module.cloudrun_processor,
    google_cloud_run_v2_service_iam_member.allow_unauthenticated,
    google_cloud_run_v2_service_iam_member.allow_pubsub_oidc
  ]
}