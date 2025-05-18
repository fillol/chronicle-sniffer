output "topic_id" {
  description = "Full ID of the main Pub/Sub topic created (projects/PROJECT_ID/topics/TOPIC_NAME)."
  value       = google_pubsub_topic.main_topic.id
}

output "topic_name" {
  description = "Short name of the main Pub/Sub topic created."
  value       = google_pubsub_topic.main_topic.name
}

output "dlq_topic_id" {
  description = "Full ID of the Dead-Letter Queue (DLQ) Pub/Sub topic created."
  value       = google_pubsub_topic.dlq_topic.id
}

output "dlq_topic_name" {
  description = "Short name of the Dead-Letter Queue (DLQ) Pub/Sub topic created."
  value       = google_pubsub_topic.dlq_topic.name
}