resource "google_cloud_run_v2_service" "processor" {
  project  = var.project_id
  name     = var.service_name
  location = var.region

  template {
    service_account = var.service_account_email # Associa il SA passato come variabile

    max_instance_request_concurrency = var.max_concurrency
    timeout                          = "600s" # Mantenuto a 10 minuti

    containers {
      image = var.image_uri
      ports { container_port = 8080 } # La porta su cui l'app ascolta

      #env { Error: Error creating Service: googleapi: Error 400: template.containers[0].env: The following reserved env names were provided: PORT, PORT. These values are automatically set by the system.
      #  name  = "PORT"
      #  value = "8080"
      #} # Assicura che PORT sia definita
      dynamic "env" {
        for_each = var.env_vars
        content {
          name  = env.key
          value = env.value
        }
      }

      resources {
        limits = {
          cpu    = var.cpu_limit
          memory = var.memory_limit
        }
      }

      # Probe di Startup (per verificare che l'app sia partita correttamente)
      startup_probe {
        initial_delay_seconds = 0
        timeout_seconds       = 5
        period_seconds        = 10
        failure_threshold     = 3
        http_get {   # Assumendo che la tua app risponda a '/' con 2xx se sta bene
          path = "/" # Modifica se hai un health check endpoint specifico (es. /healthz)
          port = 8080
        }
      }

      # Probe di Liveness (per verificare che l'app sia ancora responsiva)
      liveness_probe {
        initial_delay_seconds = 30 # Dai tempo all'app di avviarsi prima del primo check
        timeout_seconds       = 5
        period_seconds        = 30
        failure_threshold     = 3
        http_get {
          path = "/" # Modifica se hai un health check endpoint specifico
          port = 8080
        }
      }
    }
    # scaling { min_instance_count = 0; max_instance_count = 5 } # Opzionale
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}