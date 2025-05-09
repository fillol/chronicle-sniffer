output "topic_id" {
  description = "ID completo del topic Pub/Sub creato (projects/PROJECT_ID/topics/TOPIC_NAME)."
  value       = google_pubsub_topic.main_topic.id # .id fornisce il nome completo
}

output "topic_name" {
    description = "Nome breve del topic Pub/Sub creato."
    value       = google_pubsub_topic.main_topic.name
}