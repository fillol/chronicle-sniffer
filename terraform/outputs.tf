output "incoming_pcap_bucket_id" {
  description = "ID of the GCS bucket for incoming pcaps."
  value       = module.gcs_buckets.incoming_pcap_bucket_id
}

output "processed_udm_bucket_id" {
  description = "ID of the GCS bucket for processed UDM files."
  value       = module.gcs_buckets.processed_udm_bucket_id
}

output "pubsub_topic_id" {
  description = "Full ID of the Pub/Sub topic."
  value       = module.pubsub_topic.topic_id
}

output "pubsub_subscription_id" {
  description = "Full ID of the Pub/Sub subscription."
  value       = google_pubsub_subscription.processor_subscription.id
}

output "processor_cloud_run_service_url" {
  description = "URL of the Cloud Run Processor service."
  value       = module.cloudrun_processor.service_url
}

output "sniffer_service_account_email" {
  description = "Email of the Service Account dedicated for the sniffer (for the key)."
  value       = google_service_account.sniffer_sa.email
}

output "cloud_run_service_account_email" {
  description = "Email of the Service Account for Cloud Run."
  value       = google_service_account.cloud_run_sa.email
}

output "test_vm_service_account_email" {
  description = "Email of the Service Account attached to the test VM."
  value       = google_service_account.test_vm_sa.email
}

output "test_generator_vm_ip" {
  description = "External IP address of the test VM."
  value       = module.test_generator_vm.vm_external_ip
}

output "test_generator_vm_name" {
  description = "Name of the test VM."
  value       = module.test_generator_vm.vm_name
}

output "generate_sniffer_key_command" {
  description = "gcloud command to generate the JSON key for the sniffer_sa (run locally)."
  value       = "gcloud iam service-accounts keys create ./sniffer-key.json --iam-account=${google_service_account.sniffer_sa.email}"
}

output "test_vm_sniffer_setup_instructions" {
  description = "Instructions to configure and run the sniffer on the test VM."
  value       = <<EOT

----------------------------------------------------------------------------------------------------
INSTRUCTIONS FOR THE SNIFFER ON THE TEST VM ('${module.test_generator_vm.vm_name}'):
----------------------------------------------------------------------------------------------------
The base environment on the VM has been prepared by the startup script:
- Docker and Docker Compose are installed.
- The sniffer Docker image ('${var.sniffer_image_uri}') has been pulled.
- Configuration files for the sniffer are in '/opt/sniffer_env' on the VM.
  This includes a base 'docker-compose.yml' and a 'docker-compose.override.yml'
  which configures volumes and network settings specifically for the VM.

To run the sniffer, follow these steps:

1.  PREPARE THE SNIFFER'S SERVICE ACCOUNT KEY (on YOUR LOCAL MACHINE):
    Run the gcloud command shown in the Terraform output named 'generate_sniffer_key_command'.
    This command will create (or overwrite) './sniffer-key.json' for the Service Account '${google_service_account.sniffer_sa.email}'.
    (The command will be similar to: gcloud iam service-accounts keys create ./sniffer-key.json --iam-account=${google_service_account.sniffer_sa.email})

2.  ACCESS THE TEST VM VIA SSH (from YOUR LOCAL MACHINE):
    ${module.test_generator_vm.ssh_command}

3.  COPY THE SA KEY TO THE VM (from a NEW terminal on YOUR LOCAL MACHINE):
    The VM's startup script has created the directory '/opt/gcp_sa_keys/sniffer' with open permissions.
    Copy the 'sniffer-key.json' file (generated in step 1) to this directory on the VM, ensuring it is named 'key.json':

    gcloud compute scp ./sniffer-key.json ${module.test_generator_vm.vm_name}:/opt/gcp_sa_keys/sniffer/key.json --project ${var.gcp_project_id} --zone ${module.test_generator_vm.vm_zone}

    (Note: If you encounter permission issues with 'gcloud compute scp' directly to /opt/, you can first copy the key to the VM's home directory:
       gcloud compute scp ./sniffer-key.json ${module.test_generator_vm.vm_name}:~/sniffer-key.json --project ${var.gcp_project_id} --zone ${module.test_generator_vm.vm_zone}
     Then, connect to the VM via SSH (step 2) and move the file:
       sudo mv ~/sniffer-key.json /opt/gcp_sa_keys/sniffer/key.json
     Ensure the final path on the VM is '/opt/gcp_sa_keys/sniffer/key.json'.)

4.  START THE SNIFFER (inside the SSH session on the VM):
    Navigate to the sniffer's environment directory and use Docker Compose:
    cd /opt/sniffer_env
    sudo docker-compose up -d

5.  CHECK SNIFFER LOGS (inside the SSH session on the VM):
    sudo docker logs chronicle-sniffer -f
    You should see logs indicating the activation of the SA '${google_service_account.sniffer_sa.email}' and tshark starting its capture.

6.  GENERATE NETWORK TRAFFIC ON THE VM FOR TESTING (inside the SSH session):
    ping -c 20 google.com
    curl http://example.com

7.  VERIFY THE PIPELINE:
    *   Sniffer logs: Look for GCS upload and Pub/Sub publish messages.
    *   GCS Bucket '${module.gcs_buckets.incoming_pcap_bucket_id}': .pcap files should appear.
    *   Cloud Run logs for '${module.cloudrun_processor.service_name}': Notification received and processing messages.
    *   GCS Bucket '${module.gcs_buckets.processed_udm_bucket_id}': .udm.json files should appear.

8.  TO STOP THE SNIFFER (inside the SSH session on the VM):
    cd /opt/sniffer_env
    sudo docker-compose down

9.  TO CLEAN UP ALL GCP RESOURCES (from YOUR LOCAL MACHINE, in the terraform directory):
    terraform destroy
    (Remember to also delete the local SA key file './sniffer-key.json').
----------------------------------------------------------------------------------------------------
EOT
}