data "google_project" "project" {
  project_id = var.gcp_project_id
}

# --- Service Accounts ---
resource "google_service_account" "sniffer_sa" {
  project      = var.gcp_project_id
  account_id   = "${var.base_name}-snfr-sa" # Accorciato per sicurezza lunghezza
  display_name = "Service Account for On-Prem Sniffers"
}

resource "google_service_account_key" "sniffer_sa_key" {
  service_account_id = google_service_account.sniffer_sa.name
  # Nessun lifecycle prevent_destroy = true qui, la chiave è gestita da TF
}

resource "google_service_account" "cloud_run_sa" {
  project      = var.gcp_project_id
  account_id   = "${var.base_name}-run-sa" # Accorciato
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
  source            = "./modules/test_generator_vm"
  project_id        = var.gcp_project_id
  zone              = var.test_vm_zone
  vm_name           = "${var.base_name}-test-generator"
  ssh_source_ranges = var.ssh_source_ranges

  # Passaggio delle nuove variabili per lo sniffer automatizzato
  sniffer_image_to_run    = var.sniffer_image_uri
  sniffer_gcp_project_id  = var.gcp_project_id
  sniffer_incoming_bucket = module.gcs_buckets.incoming_pcap_bucket_id
  sniffer_pubsub_topic_id = module.pubsub_topic.topic_id
  # Non passiamo più la chiave SA direttamente, verrà gestita dall'utente
  # sniffer_sa_key_json_base64 = base64encode(google_service_account_key.sniffer_sa_key.private_key)

  depends_on = [
    # google_service_account_key.sniffer_sa_key, # Non più una dipendenza diretta per i metadati
    google_service_account.sniffer_sa, # Il SA deve esistere per generare la chiave
    module.gcs_buckets,
    module.pubsub_topic
  ]
}

# --- IAM: Sniffer SA Permissions ---
resource "google_pubsub_topic_iam_member" "sniffer_sa_pubsub_publisher" {
  project = var.gcp_project_id
  topic   = module.pubsub_topic.topic_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.sniffer_sa.email}"
}

resource "google_storage_bucket_iam_member" "sniffer_sa_gcs_writer" {
  bucket = module.gcs_buckets.incoming_pcap_bucket_id
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.sniffer_sa.email}"
}

# --- IAM: Cloud Run Processor SA Permissions ---
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

# --- IAM: Permessi per OIDC Pub/Sub -> Cloud Run ---
# Permetti al SA di Pub/Sub di generare token OIDC impersonando il SA di Cloud Run
resource "google_service_account_iam_member" "pubsub_sa_token_creator_for_cloud_run_sa" {
  service_account_id = google_service_account.cloud_run_sa.name # A quale SA si applica la policy
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com" # Chi ottiene il permesso
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

# Questa risorsa è per permettere a Pub/Sub (tramite OIDC) di invocare Cloud Run.
# Il 'member' è il SA di Pub/Sub, ma il token OIDC sarà firmato con l'identità del 'cloud_run_sa'.
# Cloud Run verifica che il token sia valido e che il 'cloud_run_sa' (l'identità nel token)
# sia autorizzato a invocare il servizio.
resource "google_cloud_run_v2_service_iam_member" "allow_pubsub_oidc_invoker" {
  count      = !var.allow_unauthenticated_invocations ? 1 : 0
  project    = var.gcp_project_id
  name       = module.cloudrun_processor.service_name
  location   = module.cloudrun_processor.service_location
  role       = "roles/run.invoker"
  # L'identità che deve avere il permesso di invocare è quella specificata
  # nel token OIDC, cioè il service_account_email della push_config.
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
        service_account_email = google_service_account.cloud_run_sa.email # Il SA usato per firmare il token OIDC
        audience              = module.cloudrun_processor.service_url
      }
    }
  }
  depends_on = [
    module.cloudrun_processor,
    google_cloud_run_v2_service_iam_member.allow_unauthenticated,
    google_cloud_run_v2_service_iam_member.allow_pubsub_oidc_invoker, // Dipende dal corretto invoker
    google_service_account_iam_member.pubsub_sa_token_creator_for_cloud_run_sa // Dipende dalla configurazione tokenCreator
  ]
}