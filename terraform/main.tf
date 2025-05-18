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
  source            = "./modules/test_generator_vm"
  project_id        = var.gcp_project_id
  zone              = var.test_vm_zone
  vm_name           = "${var.base_name}-sniffer-vm"
  ssh_source_ranges = var.ssh_source_ranges

  attached_service_account_email = google_service_account.test_vm_sa.email
  startup_script_path            = "${path.module}/modules/test_generator_vm/startup_script_vm.sh"

  sniffer_image_uri_val       = var.sniffer_image_uri
  sniffer_gcp_project_id_val  = var.gcp_project_id
  sniffer_incoming_bucket_val = module.gcs_buckets.incoming_pcap_bucket_id
  sniffer_pubsub_topic_id_val = module.pubsub_topic.topic_id
  sniffer_id_val              = var.test_vm_sniffer_id

  depends_on = [
    google_service_account.sniffer_sa,
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
resource "google_storage_bucket_iam_member" "runner_incoming_bucket_metadata_reader" {
  bucket = module.gcs_buckets.incoming_pcap_bucket_id
  role   = "roles/storage.legacyBucketReader" # Contiene storage.buckets.get
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

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

# --- Cloud Logging Metrics ---
resource "google_logging_metric" "sniffer_heartbeat_metric" {
  project     = var.gcp_project_id
  name        = "sniffer_heartbeat_count"
  filter      = "resource.type=(\"gce_instance\" OR \"k8s_container\" OR \"global\") AND textPayload:\"Heartbeat.\" AND textPayload:\"(ID: \"" # Assicurati che l'ID sia presente
  description = "Counts heartbeat messages from sniffer instances."

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "sniffer_id"
      value_type  = "STRING"
      description = "Unique identifier of the sniffer instance"
    }
    labels {
      key         = "interface"
      value_type  = "STRING"
      description = "Network interface used by the sniffer"
    }
  }

  label_extractors = {
    "sniffer_id" = "REGEXP_EXTRACT(textPayload, \"\\\\(ID: ([^)]+)\\\\)\")"
    "interface"  = "REGEXP_EXTRACT(textPayload, \"\\\\(IFACE: ([^)]+)\\\\)\")"
  }
}

resource "google_logging_metric" "pcap_files_uploaded_metric" {
  project     = var.gcp_project_id
  name        = "pcap_files_uploaded_count"
  filter      = "resource.type=(\"gce_instance\" OR \"k8s_container\" OR \"global\") AND textPayload:\"Upload successful for\" AND textPayload:\"(ID: \""
  description = "Counts successfully uploaded PCAP files by sniffer instances."

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "sniffer_id"
      value_type  = "STRING"
      description = "Unique identifier of the sniffer instance"
    }
  }
  label_extractors = {
    "sniffer_id" = "REGEXP_EXTRACT(textPayload, \"\\\\(ID: ([^)]+)\\\\)\")"
  }
}

resource "google_logging_metric" "pcap_upload_errors_metric" {
  project     = var.gcp_project_id
  name        = "pcap_upload_errors_count"
  filter      = "resource.type=(\"gce_instance\" OR \"k8s_container\" OR \"global\") AND textPayload:\"Error: Failed to upload\" AND textPayload:\"(ID: \""
  description = "Counts PCAP file upload errors by sniffer instances."
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "sniffer_id"
      value_type  = "STRING"
      description = "Unique identifier of the sniffer instance"
    }
  }
  label_extractors = {
    "sniffer_id" = "REGEXP_EXTRACT(textPayload, \"\\\\(ID: ([^)]+)\\\\)\")"
  }
}

resource "google_logging_metric" "udm_events_generated_metric" {
  project     = var.gcp_project_id
  name        = "udm_events_generated_count"
  filter      = "resource.type=\"cloud_run_revision\" AND severity=\"INFO\" AND jsonPayload.message=~\"Successfully wrote [0-9]+ UDM events to\""
  description = "Counts the number of UDM events generated by the processor."

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "1"
  }
  bucket_options {
    exponential_buckets {
      num_finite_buckets = 20 # Numero di bucket, ad es. 20
      growth_factor      = 2  # Ogni bucket è 2 volte più grande del precedente
      scale              = 1  # Il primo bucket inizia intorno a 1 (o il più piccolo valore significativo)
    }
    # In alternativa, per linear_buckets:
    # linear_buckets {
    #   num_finite_buckets = 50 # ad es. 50 bucket
    #   width              = 10 # ogni bucket ha un'ampiezza di 10 eventi
    #   offset             = 0  # inizia da 0
    # }
  }
  value_extractor = "REGEXP_EXTRACT(jsonPayload.message, \"Successfully wrote ([0-9]+) UDM events to\")"
}

# --- Cloud Monitoring Dashboard ---
resource "google_monitoring_dashboard" "main_operational_dashboard" {
  project = var.gcp_project_id
  dashboard_json = templatefile("${path.module}/dashboards/main_operational_dashboard.json", {
    cloud_run_processor_service_name = module.cloudrun_processor.service_name,
    pubsub_processor_subscription_id = google_pubsub_subscription.processor_subscription.name
  })

  depends_on = [
    google_logging_metric.sniffer_heartbeat_metric,
    google_logging_metric.pcap_files_uploaded_metric,
    google_logging_metric.udm_events_generated_metric,
  ]
}

# --- Cloud Monitoring Alert Policy (Esempio) ---
resource "google_monitoring_alert_policy" "sniffer_inactive_alert" {
  count = var.alert_notification_channel_id != "" ? 1 : 0 # Crea solo se un canale è specificato

  project      = var.gcp_project_id
  display_name = "${var.base_name} - Sniffer Inactive Alert"
  combiner     = "OR"

  conditions {
    display_name = "Sniffer seems inactive (no heartbeat)"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/sniffer_heartbeat_count\" resource.type=(\"gce_instance\" OR \"k8s_container\" OR \"global\")"
      duration        = "900s" # 15 minuti
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      trigger {
        count = 1
      }
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_COUNT"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.sniffer_id"]
      }
    }
  }

  notification_channels = [var.alert_notification_channel_id]

  documentation {
    content   = "Sniffer instance (check sniffer_id label in metric) has not sent a heartbeat for 15 minutes. Please investigate the sniffer instance. Project: ${var.gcp_project_id}"
    mime_type = "text/markdown"
  }

  user_labels = {
    severity = "critical"
    team     = "secops-pipeline"
  }
}