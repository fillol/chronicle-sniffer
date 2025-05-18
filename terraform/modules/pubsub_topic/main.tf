resource "google_pubsub_topic" "main_topic" {
  project = var.project_id
  name    = var.topic_name
}

resource "google_pubsub_topic" "dlq_topic" {
  project = var.project_id
  name    = "${var.topic_name}-dlq"
}