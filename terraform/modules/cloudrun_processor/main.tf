# Questo modulo crea solo il servizio base
# L'associazione del Service Account e le policy IAM (invoker) sono gestite nel main.tf principale

resource "google_cloud_run_v2_service" "processor" {
  project  = var.project_id
  name     = var.service_name
  location = var.region

  template {
    # Il Service Account verrà aggiunto nel main.tf
    # service_account = var.service_account_email # Non definito qui

    containers {
      image = var.image_uri
      ports {
        container_port = 8080 # Porta su cui l'app Flask ascolta
      }
      env { # Imposta variabili d'ambiente base
        name  = "PORT"
        value = "8080"
      }
      dynamic "env" {
        # Aggiunge dinamicamente le variabili d'ambiente passate
        for_each = var.env_vars
        content {
          name  = env.key
          value = env.value
        }
      }
      resources {
        limits = {
          cpu    = "1000m" # 1 vCPU
          memory = "512Mi" # Adatta se necessario
        }
      }
    }
    # Timeout per le richieste (importante per l'elaborazione pcap)
    timeout = "600s" # 10 minuti, adatta se necessario

    # Scaling (opzionale)
    # scaling {
    #   min_instance_count = 0
    #   max_instance_count = 5
    # }
  }

  # Configurazione del traffico per inviare tutto alla revisione più recente
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}