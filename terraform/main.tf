data "google_project" "project" {
  project_id = var.gcp_project_id
}

# --- Service Accounts ---
resource "google_service_account" "sniffer_sa" {
  project      = var.gcp_project_id
  account_id   = "${var.base_name}-snfr-sa"
  display_name = "Service Account for On-Prem Sniffers"
}

resource "google_service_account_key" "sniffer_sa_key" {
  service_account_id = google_service_account.sniffer_sa.name
}

resource "google_service_account" "cloud_run_sa" {
  project      = var.gcp_project_id
  account_id   = "${var.base_name}-run-sa"
  display_name = "Service Account for Cloud Run Processor"
}

# --- Service Account per la VM di Test ---
resource "google_service_account" "test_vm_sa" {
  project      = var.gcp_project_id
  account_id   = "${var.base_name}-testvm-sa"
  display_name = "Service Account for Test/Sniffer VM"
}

# --- Moduli ---
module "gcs_buckets" {
  source                    = "./modules/gcs_buckets"
  project_id                = var.gcp_project_id
  location                  = var.gcs_location
  incoming_pcap_bucket_name = var.incoming_pcap_bucket_name
  processed_udm_bucket_name = var.processed_udm_bucket_name
  enable_versioning         = var.enable_bucket_versioning
  cmek_key_name             = var.cmek_key_name
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
  service_account_email = google_service_account.cloud_run_sa.email
  env_vars = {
    INCOMING_BUCKET = module.gcs_buckets.incoming_pcap_bucket_id
    OUTPUT_BUCKET   = module.gcs_buckets.processed_udm_bucket_id
    GCP_PROJECT_ID  = var.gcp_project_id
  }
  max_concurrency = var.cloud_run_max_concurrency
  cpu_limit       = var.cloud_run_cpu
  memory_limit    = var.cloud_run_memory
}

module "test_generator_vm" {
  source            = "./modules/test_generator_vm" // Path al modulo
  project_id        = var.gcp_project_id
  zone              = var.test_vm_zone
  vm_name           = "${var.base_name}-sniffer-vm" // Nome istanza VM
  ssh_source_ranges = var.ssh_source_ranges

  attached_service_account_email = google_service_account.test_vm_sa.email                         // SA dedicato per la VM
  startup_script_path            = "${path.module}/modules/test_generator_vm/startup_script_vm.sh" // Path allo script

  // Variabili per i metadati (devono corrispondere a quelle nel variables.tf del modulo)
  sniffer_image_uri_val       = var.sniffer_image_uri
  sniffer_gcp_project_id_val  = var.gcp_project_id
  sniffer_incoming_bucket_val = module.gcs_buckets.incoming_pcap_bucket_id
  sniffer_pubsub_topic_id_val = module.pubsub_topic.topic_id

  depends_on = [
    google_service_account.sniffer_sa, // Il SA sniffer deve esistere per l'output 'generate_sniffer_key_command'
    //google_project_iam_member.test_vm_sa_artifact_registry_reader, => inutile se usiamo dockerhub
    module.gcs_buckets,
    module.pubsub_topic
  ]
}

# --- IAM: Sniffer SA Permissions (per la chiave SA che l'utente monterà) ---       ======================================= ATTESA PUB/SUB ADMIN
# resource "google_pubsub_topic_iam_member" "sniffer_sa_pubsub_publisher" {
#   project = var.gcp_project_id
#   topic   = module.pubsub_topic.topic_id
#   role    = "roles/pubsub.publisher"
#   member  = "serviceAccount:${google_service_account.sniffer_sa.email}"
# }

resource "google_storage_bucket_iam_member" "sniffer_sa_gcs_writer" {
  bucket = module.gcs_buckets.incoming_pcap_bucket_id
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.sniffer_sa.email}"
}

# --- IAM: Cloud Run Processor SA Permissions ---

# Permesso per storage.buckets.get sul bucket INCOMING
resource "google_storage_bucket_iam_member" "runner_incoming_bucket_metadata_reader" {
  bucket = module.gcs_buckets.incoming_pcap_bucket_id
  role   = "roles/storage.legacyBucketReader" # Contiene storage.buckets.get
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Permesso per storage.buckets.get sul bucket OUTPUT
resource "google_storage_bucket_iam_member" "runner_output_bucket_metadata_reader" {
  bucket = module.gcs_buckets.processed_udm_bucket_id
  role   = "roles/storage.legacyBucketReader" # Contiene storage.buckets.get
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

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

# La risorsa runner_gcs_output_viewer è ridondante se runner_gcs_writer è già presente
# perché roles/storage.objectCreator include i permessi di roles/storage.objectViewer.
# Puoi commentarla o rimuoverla per pulizia, ma non è la causa dell'errore attuale.
# resource "google_storage_bucket_iam_member" "runner_gcs_output_viewer" {
#   bucket = module.gcs_buckets.processed_udm_bucket_id
#   role   = "roles/storage.objectViewer"
#   member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
# }

# --- IAM: Permessi per OIDC Pub/Sub -> Cloud Run ---
resource "google_service_account_iam_member" "pubsub_sa_token_creator_for_cloud_run_sa" {
  service_account_id = google_service_account.cloud_run_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

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

resource "google_cloud_run_v2_service_iam_member" "allow_pubsub_oidc_invoker" {
  count      = !var.allow_unauthenticated_invocations ? 1 : 0
  project    = var.gcp_project_id
  name       = module.cloudrun_processor.service_name
  location   = module.cloudrun_processor.service_location
  role       = "roles/run.invoker"
  member     = "serviceAccount:${google_service_account.cloud_run_sa.email}"
  depends_on = [module.cloudrun_processor, google_service_account.cloud_run_sa]
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
    google_cloud_run_v2_service_iam_member.allow_pubsub_oidc_invoker,
    google_service_account_iam_member.pubsub_sa_token_creator_for_cloud_run_sa
  ]
}