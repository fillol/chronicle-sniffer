// --- GCP Project Data ---
// Retrieves information about the current GCP project.
data "google_project" "project" {
  project_id = var.gcp_project_id
}

// --- Service Accounts ---
// Defines Service Accounts (SAs) for different components of the pipeline,
// adhering to the principle of least privilege.

// Service Account for on-premises/edge sniffer instances.
// This SA will be used by sniffer containers to authenticate with GCP services (GCS, Pub/Sub).
resource "google_service_account" "sniffer_sa" {
  project      = var.gcp_project_id
  account_id   = "${var.base_name}-snfr-sa"
  display_name = "Service Account for On-Prem Sniffers"
}

// Generates a key for the sniffer Service Account.
// This key will be downloaded and used by on-premises sniffer instances.
resource "google_service_account_key" "sniffer_sa_key" {
  service_account_id = google_service_account.sniffer_sa.name
}

// Service Account for the Cloud Run processor service.
// This SA defines the identity and permissions of the PCAP processing service.
resource "google_service_account" "cloud_run_sa" {
  project      = var.gcp_project_id
  account_id   = "${var.base_name}-run-sa"
  display_name = "Service Account for Cloud Run Processor"
}

// Service Account for the optional test VM.
// Used by the GCE instance that can simulate an on-premises sniffer environment.
resource "google_service_account" "test_vm_sa" {
  project      = var.gcp_project_id
  account_id   = "${var.base_name}-testvm-sa"
  display_name = "Service Account for Test/Sniffer VM"
}

// --- Core Infrastructure Modules ---
// These modules provision the foundational components of the pipeline.

// GCS Buckets Module:
// Manages two GCS buckets:
// 1. Incoming PCAPs: Stores raw .pcap files uploaded by sniffers.
// 2. Processed UDM: Stores UDM JSON files after processing by Cloud Run.
module "gcs_buckets" {
  source                    = "./modules/gcs_buckets"
  project_id                = var.gcp_project_id
  location                  = var.gcs_location
  incoming_pcap_bucket_name = var.incoming_pcap_bucket_name
  processed_udm_bucket_name = var.processed_udm_bucket_name
  enable_versioning         = var.enable_bucket_versioning
  cmek_key_name             = var.cmek_key_name
}

// Pub/Sub Topic Module:
// Manages the Pub/Sub topic used for notifications when new .pcap files are uploaded.
// Also creates a Dead-Letter Queue (DLQ) topic for unprocessable messages.
module "pubsub_topic" {
  source     = "./modules/pubsub_topic" # Ensure this module creates main and DLQ topics
  project_id = var.gcp_project_id
  topic_name = "${var.base_name}-pcap-notifications"
  # The module should internally handle the DLQ topic name, e.g., by appending "-dlq"
}

// Cloud Run Processor Module:
// Deploys the PCAP processing application as a Cloud Run service.
// Configures the service with necessary environment variables, resources, and scaling settings.
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

// Test Generator VM Module (Optional):
// Provisions a GCE instance to simulate an on-premises sniffer environment for testing purposes.
// The startup script prepares the VM with Docker and pulls the sniffer image.
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
  sniffer_pubsub_topic_id_val = module.pubsub_topic.topic_id // Assumes module.pubsub_topic outputs 'topic_id' (full path)
  sniffer_id_val              = var.test_vm_sniffer_id

  depends_on = [
    google_service_account.sniffer_sa, // Sniffer SA should exist before VM setup references it implicitly via outputs
    module.gcs_buckets,
    module.pubsub_topic
  ]
}

// --- IAM Permissions ---
// Configures IAM policies to grant necessary permissions to Service Accounts.

// IAM for Sniffer Service Account (used via downloaded key):
// Grants permission to write .pcap files to the incoming GCS bucket and to publish notifications to the Topic.

resource "google_pubsub_topic_iam_member" "sniffer_sa_pubsub_publisher" {
  project = var.gcp_project_id
  topic   = module.pubsub_topic.topic_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.sniffer_sa.email}"
}

resource "google_storage_bucket_iam_member" "sniffer_sa_gcs_writer" {
  bucket = module.gcs_buckets.incoming_pcap_bucket_id
  role   = "roles/storage.objectCreator" // Allows creating objects in the bucket
  member = "serviceAccount:${google_service_account.sniffer_sa.email}"
}

// IAM for Cloud Run Processor Service Account:
// Grants permissions required by the Cloud Run service to operate.
// - Read metadata for both buckets (for startup verification).
// - Read objects from the incoming GCS bucket (to download .pcap files).
// - Create objects in the processed UDM GCS bucket (to upload .udm.json files).

resource "google_storage_bucket_iam_member" "runner_incoming_bucket_metadata_reader" {
  bucket = module.gcs_buckets.incoming_pcap_bucket_id
  role   = "roles/storage.legacyBucketReader" // Includes storage.buckets.get for bucket existence check
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_storage_bucket_iam_member" "runner_output_bucket_metadata_reader" {
  bucket = module.gcs_buckets.processed_udm_bucket_id
  role   = "roles/storage.legacyBucketReader" // Includes storage.buckets.get
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_storage_bucket_iam_member" "runner_gcs_writer" {
  bucket = module.gcs_buckets.processed_udm_bucket_id
  role   = "roles/storage.objectCreator" // Allows writing UDM files
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_storage_bucket_iam_member" "runner_gcs_reader" {
  bucket = module.gcs_buckets.incoming_pcap_bucket_id
  role   = "roles/storage.objectViewer" // Allows reading PCAP files
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

// IAM for OIDC-based Pub/Sub to Cloud Run Invocation:
// Allows the GCP Pub/Sub service agent to generate OIDC tokens for the Cloud Run SA.
// This is necessary for secure, authenticated invocations from Pub/Sub to Cloud Run.
resource "google_service_account_iam_member" "pubsub_sa_token_creator_for_cloud_run_sa" {
  service_account_id = google_service_account.cloud_run_sa.name // The SA that Cloud Run runs as
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com" // GCP-managed Pub/Sub SA
}

// Cloud Run Invocation Permissions:
// Controls who can invoke the Cloud Run processor service.
// By default, restricted to OIDC-authenticated Pub/Sub calls via the Cloud Run SA.
// Optionally allows unauthenticated invocations if var.allow_unauthenticated_invocations is true.

resource "google_cloud_run_v2_service_iam_member" "allow_unauthenticated" {
  count      = var.allow_unauthenticated_invocations ? 1 : 0
  project    = var.gcp_project_id
  name       = module.cloudrun_processor.service_name
  location   = module.cloudrun_processor.service_location
  role       = "roles/run.invoker"
  member     = "allUsers" // Allows public access if enabled
  depends_on = [module.cloudrun_processor]
}

resource "google_cloud_run_v2_service_iam_member" "allow_pubsub_oidc_invoker" {
  count      = !var.allow_unauthenticated_invocations ? 1 : 0
  project    = var.gcp_project_id
  name       = module.cloudrun_processor.service_name
  location   = module.cloudrun_processor.service_location
  role       = "roles/run.invoker"
  member     = "serviceAccount:${google_service_account.cloud_run_sa.email}" // Allows invocation by the Cloud Run SA (used by Pub/Sub OIDC)
  depends_on = [module.cloudrun_processor, google_service_account.cloud_run_sa]
}

// --- Pub/Sub Subscription ---
// Creates a push subscription to the PCAP notifications topic.
// This subscription delivers messages to the Cloud Run processor service endpoint.
// Configured with OIDC authentication (if var.allow_unauthenticated_invocations is false)
// and a dead-letter policy for unprocessable messages.
resource "google_pubsub_subscription" "processor_subscription" {
  project              = var.gcp_project_id
  name                 = "${var.base_name}-processor-sub"
  topic                = module.pubsub_topic.topic_id // Main topic for PCAP notifications
  ack_deadline_seconds = 600                          // Time allowed for Cloud Run to process a message

  push_config {
    push_endpoint = module.cloudrun_processor.service_url // Cloud Run service URL
    dynamic "oidc_token" {
      for_each = !var.allow_unauthenticated_invocations ? [1] : []
      content {
        service_account_email = google_service_account.cloud_run_sa.email // SA used for OIDC token generation
        audience              = module.cloudrun_processor.service_url     // Audience for the OIDC token
      }
    }
  }

  dead_letter_policy {
    dead_letter_topic     = module.pubsub_topic.dlq_topic_id // DLQ topic for failed messages
    max_delivery_attempts = 5                                // Max retries before sending to DLQ
  }

  depends_on = [
    module.cloudrun_processor,
    google_cloud_run_v2_service_iam_member.allow_unauthenticated,
    google_cloud_run_v2_service_iam_member.allow_pubsub_oidc_invoker,
    google_service_account_iam_member.pubsub_sa_token_creator_for_cloud_run_sa,
    module.pubsub_topic // Ensures DLQ topic exists if the module creates it
  ]
}

// --- Cloud Logging Metrics ---
// Defines custom metrics based on log entries for monitoring pipeline health and performance.
// These metrics are used in the Cloud Monitoring Dashboard.

// Sniffer Heartbeat Metric: Counts heartbeat messages from sniffer instances.
resource "google_logging_metric" "sniffer_heartbeat_metric" {
  project     = var.gcp_project_id
  name        = "sniffer_heartbeat_count"
  filter      = "resource.type=(\"gce_instance\" OR \"k8s_container\" OR \"global\") AND textPayload:\"Heartbeat.\" AND textPayload:\"(ID: \""
  description = "Counts heartbeat messages from sniffer instances."

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Sniffer Heartbeats"
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

// PCAP Files Uploaded Metric: Counts successfully uploaded PCAP files by sniffers.
resource "google_logging_metric" "pcap_files_uploaded_metric" {
  project     = var.gcp_project_id
  name        = "pcap_files_uploaded_count"
  filter      = "resource.type=(\"gce_instance\" OR \"k8s_container\" OR \"global\") AND textPayload:\"Upload successful for\" AND textPayload:\"(ID: \""
  description = "Counts successfully uploaded PCAP files by sniffer instances."

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "PCAP Files Uploaded"
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

// PCAP Upload Errors Metric: Counts PCAP file upload errors by sniffers.
resource "google_logging_metric" "pcap_upload_errors_metric" {
  project     = var.gcp_project_id
  name        = "pcap_upload_errors_count"
  filter      = "resource.type=(\"gce_instance\" OR \"k8s_container\" OR \"global\") AND textPayload:\"Error: Failed to upload\" AND textPayload:\"(ID: \""
  description = "Counts PCAP file upload errors by sniffer instances."

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "PCAP Upload Errors"
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

# // Processor UDM Packets Processed Metric: Distribution of UDM packets processed per file.
# resource "google_logging_metric" "processor_udm_packets_processed_metric" {
#   project     = var.gcp_project_id
#   name        = "processor_udm_packets_processed_count"
#   filter      = "resource.type=\"cloud_run_revision\" AND logName=~\"projects/${var.gcp_project_id}/logs/run.googleapis.com%2Fstdout\" AND textPayload=~\"json2udm_cloud.py (stdout|stderr):.*UDM_PACKETS_PROCESSED:\""
#   description = "Distribution of UDM packets successfully processed into UDM events by the processor per file."

#   metric_descriptor {
#     metric_kind  = "DELTA"
#     value_type   = "DISTRIBUTION"
#     unit         = "1"
#     display_name = "Processor UDM Packets Processed"
#     labels {
#       key         = "filename"
#       value_type  = "STRING"
#       description = "Name of the source JSON file processed"
#     }
#   }
#   bucket_options {
#     exponential_buckets {
#       num_finite_buckets = 20
#       growth_factor      = 2
#       scale              = 1
#     }
#   }
#   value_extractor = "REGEXP_EXTRACT(textPayload, \"UDM_PACKETS_PROCESSED: ([0-9]+)\")"
#   label_extractors = {
#     "filename" = "REGEXP_EXTRACT(textPayload, \"UDM_PACKETS_PROCESSED: [0-9]+ FILE: ([^\\\\s]+)\")" // Corretto qui
#   }
# }

// Sniffer TShark Status Running Count Metric: Counts logs indicating tshark is running.
# resource "google_logging_metric" "sniffer_tshark_status_running_count" {
#   project     = var.gcp_project_id
#   name        = "sniffer_tshark_status_running_count"
#   filter      = "resource.type=(\"gce_instance\" OR \"k8s_container\" OR \"global\") AND textPayload:\"TSHARK_STATUS: running\" AND textPayload:\"(ID: \""
#   description = "Counts when tshark is reported as running by a sniffer."

#   metric_descriptor {
#     metric_kind  = "DELTA"
#     value_type   = "INT64"
#     unit         = "1"
#     display_name = "Sniffer TShark Running Status"
#     labels {
#       key         = "sniffer_id"
#       value_type  = "STRING"
#       description = "Unique identifier of the sniffer instance"
#     }
#   }
#   label_extractors = {
#     "sniffer_id" = "REGEXP_EXTRACT(textPayload, \"\\\\(ID: ([^)]+)\\\\)\")"
#   }
# }

// PCAP File Size Metric: Distribution of uploaded PCAP file sizes by sniffers.
# resource "google_logging_metric" "pcap_file_size_metric" {
#   project     = var.gcp_project_id
#   name        = "pcap_file_size_bytes"
#   filter      = "resource.type=(\"gce_instance\" OR \"k8s_container\" OR \"global\") AND textPayload:\"PCAP_SIZE_BYTES:\" AND textPayload:\"(ID: \""
#   description = "Distribution of uploaded PCAP file sizes in bytes."

#   metric_descriptor {
#     metric_kind  = "DELTA"
#     value_type   = "DISTRIBUTION"
#     unit         = "By"
#     display_name = "PCAP File Size"
#     labels {
#       key         = "sniffer_id"
#       value_type  = "STRING"
#       description = "Unique identifier of the sniffer instance"
#     }
#   }
#   bucket_options {
#     linear_buckets {
#       num_finite_buckets = 20
#       width              = 1048576
#       offset             = 0
#     }
#   }
#   value_extractor = "REGEXP_EXTRACT(textPayload, \"PCAP_SIZE_BYTES: ([0-9]+)\")"
#   label_extractors = {
#     "sniffer_id" = "REGEXP_EXTRACT(textPayload, \"\\\\(ID: ([^)]+)\\\\)\")"
#   }
# }

// Pub/Sub Publish Errors Metric: Counts errors when sniffers fail to publish notifications.
resource "google_logging_metric" "pubsub_publish_errors_metric" {
  project     = var.gcp_project_id
  name        = "pubsub_publish_errors_count"
  filter      = "resource.type=(\"gce_instance\" OR \"k8s_container\" OR \"global\") AND textPayload:\"Error: Failed to publish notification for\" AND textPayload:\"(ID: \""
  description = "Counts Pub/Sub notification publishing errors by sniffer instances."

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Sniffer PubSub Publish Errors"
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

// Processor PCAP Download Success Metric: Counts successful PCAP downloads by the processor.
resource "google_logging_metric" "pcap_download_success_processor" {
  project     = var.gcp_project_id
  name        = "processor_pcap_download_success_count"
  filter      = "resource.type=\"cloud_run_revision\" AND textPayload=~\"INFO - Download complete for\""
  description = "Counts successful PCAP downloads by the processor."

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Processor PCAP Download Success"
  }
}

// Processor PCAP Download Not Found Metric: Counts "file not found" errors during PCAP download.
resource "google_logging_metric" "pcap_download_notfound_processor" {
  project     = var.gcp_project_id
  name        = "processor_pcap_download_notfound_count"
  filter      = "resource.type=\"cloud_run_revision\" AND textPayload=~\"ERROR - Error: pcap gs://.* not found.\""
  description = "Counts PCAP not found errors during download by the processor."

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Processor PCAP Download Not Found"
  }
}

// Processor TShark Conversion Success Metric: Counts successful tshark conversions.
resource "google_logging_metric" "tshark_conversion_success_processor" {
  project     = var.gcp_project_id
  name        = "processor_tshark_conversion_success_count"
  filter      = "resource.type=\"cloud_run_revision\" AND textPayload=~\"INFO - tshark conversion successful:\""
  description = "Counts successful TShark conversions by the processor."

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Processor TShark Conversion Success"
  }
}

// Processor TShark Conversion Error Metric: Counts errors during tshark conversion.
resource "google_logging_metric" "tshark_conversion_error_processor" {
  project     = var.gcp_project_id
  name        = "processor_tshark_conversion_error_count"
  filter      = "resource.type=\"cloud_run_revision\" AND textPayload=~\"ERROR - Subprocess error \\\\(tshark\\\\):\""
  description = "Counts TShark conversion errors by the processor."

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Processor TShark Conversion Errors"
  }
}

// Processor UDM Packet Processing Errors Metric: Distribution of packets that errored during UDM conversion.
# resource "google_logging_metric" "udm_packet_processing_errors" {
#   project     = var.gcp_project_id
#   name        = "processor_udm_packet_errors_count"
#   filter      = "resource.type=\"cloud_run_revision\" AND logName=~\"projects/${var.gcp_project_id}/logs/run.googleapis.com%2Fstdout\" AND textPayload=~\"json2udm_cloud.py (stdout|stderr):.*UDM_PACKET_ERRORS:\""
#   description = "Distribution of packets that resulted in an error during UDM conversion per file."

#   metric_descriptor {
#     metric_kind  = "DELTA"
#     value_type   = "DISTRIBUTION"
#     unit         = "1"
#     display_name = "Processor UDM Packet Errors"
#     labels {
#       key         = "filename"
#       value_type  = "STRING"
#       description = "Name of the source JSON file with packet errors"
#     }
#   }
#   value_extractor = "REGEXP_EXTRACT(textPayload, \"UDM_PACKET_ERRORS: ([0-9]+)\")"
#   bucket_options {
#     linear_buckets {
#       num_finite_buckets = 10
#       width              = 1
#       offset             = 0
#     }
#   }
#   label_extractors = {
#     "filename" = "REGEXP_EXTRACT(textPayload, \"UDM_PACKET_ERRORS: [0-9]+ FILE: ([^\\\\s]+)\")" // Corretto qui
#   }
# }

// Processor UDM Upload Success Metric: Counts successful UDM file uploads.
resource "google_logging_metric" "udm_upload_success_processor" {
  project     = var.gcp_project_id
  name        = "processor_udm_upload_success_count"
  filter      = "resource.type=\"cloud_run_revision\" AND textPayload=~\"INFO - Upload complete for .*udm.json\""
  description = "Counts successful UDM uploads by the processor."

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Processor UDM Upload Success"
  }
}

// Processor PCAP Processing Latency Metric: Distribution of end-to-end processing time per PCAP file.
resource "google_logging_metric" "processor_pcap_latency" {
  project     = var.gcp_project_id
  name        = "processor_pcap_processing_latency_seconds"
  filter      = "resource.type=\"cloud_run_revision\" AND textPayload=~\"INFO - PROCESSING_DURATION_SECONDS:\""
  description = "Distribution of PCAP file processing latency by the processor in seconds."

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "DISTRIBUTION"
    unit         = "s"
    display_name = "Processor PCAP Processing Latency"
  }
  bucket_options {
    exponential_buckets {
      num_finite_buckets = 20
      growth_factor      = 1.5
      scale              = 1
    }
  }
  value_extractor = "REGEXP_EXTRACT(textPayload, \"PROCESSING_DURATION_SECONDS: ([0-9]+\\\\.?[0-9]*)\")"
}

// --- Cloud Monitoring Dashboard ---
// Defines the operational dashboard using a JSON template file.
// This dashboard visualizes the custom metrics and standard GCP service metrics.
resource "google_monitoring_dashboard" "main_operational_dashboard" {
  project = var.gcp_project_id
  dashboard_json = templatefile("${path.module}/dashboards/main_operational_dashboard.json", {
    cloud_run_processor_service_name = module.cloudrun_processor.service_name,
    pubsub_processor_subscription_id = google_pubsub_subscription.processor_subscription.name
    // Add other variables here if the dashboard template needs them.
  })

  depends_on = [ // Ensure metrics are created before the dashboard attempts to use them.
    google_logging_metric.sniffer_heartbeat_metric,
    google_logging_metric.pcap_files_uploaded_metric,
    // google_logging_metric.processor_udm_packets_processed_metric, // RIMOSSO
    google_logging_metric.pcap_upload_errors_metric,
    // google_logging_metric.sniffer_tshark_status_running_count,    // RIMOSSO
    // google_logging_metric.pcap_file_size_metric,                  // RIMOSSO
    google_logging_metric.pubsub_publish_errors_metric,
    google_logging_metric.pcap_download_success_processor,
    google_logging_metric.pcap_download_notfound_processor,
    google_logging_metric.tshark_conversion_success_processor,
    google_logging_metric.tshark_conversion_error_processor,
    // google_logging_metric.udm_packet_processing_errors,           // RIMOSSO
    google_logging_metric.udm_upload_success_processor,
    google_logging_metric.processor_pcap_latency
  ]
}

// --- Cloud Monitoring Alert Policy (Example) ---
// Defines an example alert policy for inactive sniffers.
// This policy triggers if a sniffer instance stops sending heartbeats.
// It creates the alert only if a notification channel ID is provided.
resource "google_monitoring_alert_policy" "sniffer_inactive_alert" {
  count = var.alert_notification_channel_id != "" ? 1 : 0

  project      = var.gcp_project_id
  display_name = "${var.base_name} - Sniffer Inactive Alert"
  combiner     = "OR" // How to combine multiple conditions (if any)

  conditions {
    display_name = "Sniffer seems inactive (no heartbeat)"
    condition_threshold {
      // Monitors the custom sniffer_heartbeat_count metric.
      filter          = "metric.type=\"logging.googleapis.com/user/sniffer_heartbeat_count\" resource.type=(\"gce_instance\" OR \"k8s_container\" OR \"global\")"
      duration        = "900s"          // Alert if condition met for 15 minutes
      comparison      = "COMPARISON_LT" // Triggers if count is less than threshold
      threshold_value = 1               // Expect at least 1 heartbeat in the alignment period
      trigger {                         // How many times the condition must be met within the duration
        count = 1
      }
      aggregations {
        alignment_period   = "60s"              // Aggregate data points over 60 seconds
        per_series_aligner = "ALIGN_COUNT_TRUE" // Count true values (for DELTA/INT64, if a point exists, it's 'true')
        // For a rate, ALIGN_RATE would be appropriate.
        cross_series_reducer = "REDUCE_SUM"                // Sum counts across all series (if not grouping by sniffer_id for alert)
        group_by_fields      = ["metric.label.sniffer_id"] // Alert per sniffer_id
      }
    }
  }

  notification_channels = [var.alert_notification_channel_id] // Send alerts to this channel

  documentation {
    content   = "Sniffer instance (check sniffer_id label in metric) has not sent a heartbeat for 15 minutes. Please investigate the sniffer instance. Project: ${var.gcp_project_id}"
    mime_type = "text/markdown" // Format for the alert documentation
  }

  user_labels = { // Custom labels for organizing/filtering alerts
    severity = "critical"
    team     = "secops-pipeline"
  }
}