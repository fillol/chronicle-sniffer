# terraform/main.tf - File principale che orchestra moduli e IAM

# --- Moduli ---

module "gcs_buckets" {
  source                    = "./modules/gcs_buckets"
  location                  = var.gcs_location
  incoming_pcap_bucket_name = var.incoming_pcap_bucket_name
  processed_udm_bucket_name = var.processed_udm_bucket_name
}

module "pubsub_topic" {
  source     = "./modules/pubsub_topic"
  project_id = var.gcp_project_id
  topic_name = "${var.base_name}-pcap-notifications"
}

module "cloudrun_processor" {
  source          = "./modules/cloudrun_processor"
  project_id      = var.gcp_project_id
  region          = var.gcp_region
  service_name    = "${var.base_name}-processor"
  image_uri       = var.processor_cloud_run_image
  # Passa i nomi dei bucket come variabili d'ambiente al container
  env_vars = {
    INCOMING_BUCKET = module.gcs_buckets.incoming_pcap_bucket_id
    OUTPUT_BUCKET   = module.gcs_buckets.processed_udm_bucket_id
    GCP_PROJECT_ID  = var.gcp_project_id # Utile per logging esplicito se necessario
  }
  # Il Service Account verrà definito e associato qui sotto
}

module "test_generator_vm" {
  source     = "./modules/test_generator_vm"
  project_id = var.gcp_project_id
  zone       = var.test_vm_zone
  vm_name    = "${var.base_name}-test-generator"
  # Nota: Lo script di startup di default usa tcpreplay,
  # assicurati che un file sample.pcap sia disponibile sulla VM
  # o modifica lo script.
}

# --- IAM: Service Accounts ---

resource "google_service_account" "sniffer_sa" {
  project      = var.gcp_project_id
  account_id   = "${var.base_name}-sniffer-sa"
  display_name = "Service Account for On-Prem Wireshark Sniffers"
}

resource "google_service_account" "cloud_run_sa" {
  project      = var.gcp_project_id
  account_id   = "${var.base_name}-runner-sa"
  display_name = "Service Account for Cloud Run UDM Processor"
}

# --- IAM: Sniffer Permissions ---

resource "google_pubsub_topic_iam_member" "sniffer_pubsub_publisher" {
  project = var.gcp_project_id
  topic   = module.pubsub_topic.topic_id # Usa l'ID completo del topic dall'output del modulo
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.sniffer_sa.email}"
}

resource "google_storage_bucket_iam_member" "sniffer_gcs_writer" {
  bucket = module.gcs_buckets.incoming_pcap_bucket_id # Usa l'ID del bucket dall'output del modulo
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.sniffer_sa.email}"
}

# --- IAM: Cloud Run Processor Permissions ---

# Associa il Service Account al servizio Cloud Run
resource "google_cloud_run_v2_service" "processor_service_update_sa" {
  # Usa i dati del servizio creato dal modulo
  name     = module.cloudrun_processor.service_name
  location = module.cloudrun_processor.service_location
  project  = var.gcp_project_id

  # Sovrascrivi solo il template per aggiungere il SA
  template {
    service_account = google_service_account.cloud_run_sa.email
    # Mantieni le altre configurazioni del template (contenitori, env)
    # Terraform farà il merge con la configurazione definita nel modulo
    containers {
      image = var.processor_cloud_run_image # Deve corrispondere a quella nel modulo
       env {
          name = "INCOMING_BUCKET"
          value = module.gcs_buckets.incoming_pcap_bucket_id
      }
      env {
          name = "OUTPUT_BUCKET"
          value = module.gcs_buckets.processed_udm_bucket_id
      }
      env {
          name = "GCP_PROJECT_ID"
          value = var.gcp_project_id
      }
    }
  }
  # Assicura che questa modifica avvenga dopo la creazione iniziale del servizio nel modulo
  depends_on = [module.cloudrun_processor]

  # Ignora le modifiche al template non relative al service account per evitare conflitti
  lifecycle {
    ignore_changes = [
      template[0].containers,
      template[0].scaling,
      template[0].volumes,
      # Aggiungi altri campi del template se necessario
    ]
  }
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

resource "google_project_iam_member" "runner_logging_writer" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Permetti invocazioni al servizio Cloud Run
# Opzione 1: Non autenticate (più semplice per Pub/Sub push senza OIDC)
resource "google_cloud_run_v2_service_iam_member" "allow_unauthenticated" {
  count    = var.allow_unauthenticated_invocations ? 1 : 0
  project  = var.gcp_project_id
  name     = module.cloudrun_processor.service_name # Usa il nome dall'output del modulo
  location = module.cloudrun_processor.service_location # Usa la location dall'output
  role     = "roles/run.invoker"
  member   = "allUsers"

  depends_on = [module.cloudrun_processor]
}

# Opzione 2: Permetti solo a Pub/Sub (richiede OIDC nella sottoscrizione)
# Nota: Questa è l'opzione più sicura per produzione.
data "google_project" "project" {
  project_id = var.gcp_project_id
}

resource "google_cloud_run_v2_service_iam_member" "allow_pubsub_oidc" {
  count    = !var.allow_unauthenticated_invocations ? 1 : 0
  project  = var.gcp_project_id
  name     = module.cloudrun_processor.service_name
  location = module.cloudrun_processor.service_location
  role     = "roles/run.invoker"
  member   = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com" # Pub/Sub Service Agent

  depends_on = [module.cloudrun_processor]
}


# --- Pub/Sub Subscription ---
# Creata qui nel main per poter usare l'URL del servizio Cloud Run dall'output del modulo

resource "google_pubsub_subscription" "processor_subscription" {
  project = var.gcp_project_id
  name    = "${var.base_name}-processor-sub"
  topic   = module.pubsub_topic.topic_id # Nome completo del topic

  ack_deadline_seconds = 600 # Max 10 minuti per processare

  push_config {
    push_endpoint = module.cloudrun_processor.service_url # URL dall'output del modulo Cloud Run

    # Configura OIDC se NON si usa allow_unauthenticated_invocations
    dynamic "oidc_token" {
       for_each = !var.allow_unauthenticated_invocations ? [1] : []
       content {
         # Il Service Account che Pub/Sub userà per generare il token OIDC
         # Può essere il SA di Cloud Run stesso o un SA dedicato per Pub/Sub push
         service_account_email = google_service_account.cloud_run_sa.email
         audience              = module.cloudrun_processor.service_url # L'audience DEVE corrispondere all'URL del servizio
       }
    }
  }

  # Assicura che il servizio Cloud Run e le relative policy IAM esistano prima
  depends_on = [
    module.cloudrun_processor,
    google_cloud_run_v2_service_iam_member.allow_unauthenticated,
    google_cloud_run_v2_service_iam_member.allow_pubsub_oidc
  ]
}
