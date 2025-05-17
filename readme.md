# Chronicle-Sniffer: A Scalable Wireshark-to-SecOps Pipeline on GCP

**Author:** [Filippo Lucchesi](https://github.com/fillol)  
**Course:** [Scalable and Reliable Services](https://www.unibo.it/en/study/course-units-transferable-skills-moocs/course-unit-catalogue/course-unit/2024/472686), [University of Bologna](https://www.unibo.it)  
**Evolution of:** [Wireshark-to-Chronicle-Pipeline (Cybersecurity Projects 2024)](https://github.com/fillol/Wireshark-to-Chronicle-Pipeline)  

This project implements a robust, scalable, and event-driven pipeline to capture network traffic using `tshark`, process it, and transform it into the Unified Data Model (UDM) for security analytics, all orchestrated on Google Cloud Platform (GCP) using Terraform. It evolves from an initial local processing concept into a cloud-native solution designed for enhanced reliability and scalability.

## Key Features & Enhancements

*   **Hybrid Capture Model**: A Dockerized `tshark` sniffer designed for on-premises or edge deployment handles initial packet capture, automatically rotating PCAP files, uploading them to Google Cloud Storage (GCS), and notifying a Pub/Sub topic.
*   **Serverless, Scalable Processing**: A GCP Cloud Run service acts as a serverless processor, triggered by Pub/Sub messages, to manage the demanding PCAP-to-UDM transformation.
*   **Optimized Core Transformation (`json2udm_cloud.py`)**: The central Python script, originally designed for local batch processing, has been significantly re-engineered. It now employs **streaming JSON parsing (`ijson`)** to handle potentially massive `tshark` outputs efficiently within Cloud Run's memory constraints, mapping raw packet data to UDM. This is the analytical heart of the project.
*   **Resilient and Decoupled Architecture**: Leverages a Pub/Sub-driven workflow for loose coupling between capture and processing. Includes dead-letter queue (DLQ) support for failed messages, Cloud Run health probes for service reliability, and robust error handling within the processing logic.
*   **Infrastructure as Code (IaC)**: The entire GCP infrastructure is managed by Terraform, promoting repeatability, version control, and automated provisioning.
*   **Minimal On-Premises Footprint**: All heavy computation (JSON parsing, UDM mapping) is offloaded to the cloud, requiring minimal resources on the capture (sniffer) side.
*   **Secure by Design**: Implements IAM least-privilege principles for service accounts, OIDC-authenticated Cloud Run invocations from Pub/Sub, and secure SA key management for the on-premises sniffer.
*   **Observable System**: Integrates with Cloud Logging for structured, centralized application and service logs, and Cloud Monitoring for key operational metrics.

---

## Architecture Overview

The system employs a distributed, event-driven architecture:

1.  **Capture & Notify (On-Premises/Edge - `sniffer` container)**:
    *   The `sniffer` container runs `tshark` on a designated network interface.
    *   PCAP files are rotated based on size or duration.
    *   Upon rotation, the completed PCAP file is uploaded to a GCS "incoming-pcaps" bucket.
    *   A notification containing the filename is published to a GCP Pub/Sub topic.
2.  **Trigger & Process (GCP - Cloud Run `processor` service)**:
    *   A Pub/Sub push subscription, secured with OIDC, invokes the `processor` Cloud Run service.
    *   The Cloud Run service:
        *   Downloads the specified PCAP file from the "incoming-pcaps" GCS bucket.
        *   Converts the PCAP to a JSON representation using an embedded `tshark` instance (`tshark -T json`).
        *   Executes the **`json2udm_cloud.py`** script, which streams the large JSON output from `tshark` and maps each packet to the UDM format.
        *   Uploads the resulting UDM JSON file to a "processed-udm" GCS bucket.
3.  **Error Handling & Observability (GCP)**:
    *   Pub/Sub push subscription is configured with a dead-letter topic to capture messages that fail processing after multiple retries.
    *   All application logs (sniffer and processor) are sent to Cloud Logging.
    *   Key service metrics (Cloud Run invocations, latency, errors; Pub/Sub message counts; GCS operations) are available in Cloud Monitoring.


## From Local Batch to Cloud-Native Streaming

This project originated from a [Cybersecurity course project](https://github.com/fillol/Wireshark-to-Chronicle-Pipeline) focused on local PCAP processing. The initial `json2udm.py` script (included in the repository for reference) was designed to:
*   Load an entire `tshark`-generated JSON file into memory.
*   Iterate through the parsed packets.
*   Handle local file system operations for input and output, including splitting large UDM outputs.

**Key improvements in `json2udm_cloud.py` for this "Scalable and Reliable Services" project:**
*   **Memory Efficiency**: The most significant change is the adoption of `ijson` for streaming JSON. This allows the script to process massive `tshark` JSON outputs packet by packet, drastically reducing memory footprint and making it suitable for resource-constrained environments like Cloud Run. The original `json.loads()` on a multi-gigabyte JSON file would lead to OOM errors.
*   **Robustness**: Enhanced error handling for individual packets. Instead of potentially skipping packets or failing entirely on malformed data, the script now attempts to create a minimal UDM event даже for problematic packets, often including error details. Timestamp conversion is also more robust, with fallbacks.
*   **Cloud Environment Focus**: Removal of local file system concerns like multi-file output splitting. The script now produces a single UDM JSON output stream, which the `processor_app.py` then uploads to GCS.
*   **UDM Alignment**: The UDM structure produced has been refined to more closely align with common UDM schemas (e.g., Chronicle UDM), featuring distinct `metadata`, `principal`, `target`, and `network` sections.

These adaptations were crucial to transition the core logic from a local, batch-oriented tool to a scalable, cloud-native component.

---

## Repository Layout

```plaintext
Chronicle-sniffer/
├── terraform/                      # Terraform IaC modules and configurations
│   ├── modules/
│   │   ├── gcs_buckets/            # Manages GCS buckets
│   │   ├── pubsub_topic/           # Manages Pub/Sub topic and DLQ
│   │   ├── cloudrun_processor/     # Manages Cloud Run processor service
│   │   └── test_generator_vm/      # Optional VM for on-prem simulation
│   │       └── startup_script_vm.sh
│   ├── provider.tf
│   ├── variables.tf
│   ├── main.tf                     # Main Terraform configuration
│   ├── outputs.tf
│   └── terraform.tfvars.example    # Example variables for Terraform
├── sniffer/                        # On-Premises/Edge Sniffer component
│   ├── Dockerfile                  # Dockerfile for the sniffer
│   ├── sniffer_entrypoint.sh       # Entrypoint script for capture and upload
│   ├── compose.yml                 # Docker Compose for local sniffer testing
│   └── .env.example                # Environment variables for sniffer
├── processor/                      # Cloud Run Processor component
│   ├── Dockerfile                  # Dockerfile for the processor
│   ├── processor_app.py            # Flask app orchestrating the processing
│   ├── json2udm_cloud.py           # Core PCAP JSON to UDM transformation script (streaming version)
│   └── requirements.txt            # Python dependencies for the processor
├── LICENSE                         # MIT License
└── readme.md                       # This file (main project README)
```

---

## Prerequisites

*   A Google Cloud Platform (GCP) account with billing enabled.
*   Required GCP APIs enabled in your project: Cloud Run, Pub/Sub, Cloud Storage, IAM, Artifact Registry, Compute Engine (if using the test VM).
*   `gcloud` CLI installed and authenticated.
*   Terraform (>=1.1.0) installed.
*   Docker installed (for building images and optionally running the sniffer locally).
*   An Artifact Registry Docker repository (e.g., `chronicle-sniffer`) in your GCP project and region.

## Environment Setup

Before deploying, authenticate `gcloud` and configure Docker for Artifact Registry:

```bash
# Log in to your Google account (this will open a browser window)
gcloud auth login

# Set your default GCP project
gcloud config set project YOUR_PROJECT_ID

# Authenticate Application Default Credentials (used by Terraform and other tools)
gcloud auth application-default login

# Configure Docker to authenticate with Artifact Registry
# Replace REGION with your Artifact Registry region (e.g., europe-west8)
gcloud auth configure-docker REGION-docker.pkg.dev
```


## Quickstart Deployment

1.  **Clone the Repository**:
    ```bash
    git clone https://github.com/fillol/Chronicle-sniffer.git # Or your repo URL
    cd Chronicle-sniffer
    ```

2.  **Build and Push the Processor Docker Image**:
    Navigate to the `processor` directory and build the image, then push it to your Artifact Registry.
    ```bash
    cd processor
    # Replace REGION, YOUR_PROJECT_ID, YOUR_REPO_NAME, and TAG accordingly
    docker build -t REGION-docker.pkg.dev/YOUR_PROJECT_ID/YOUR_REPO_NAME/pcap-processor:latest .
    docker push REGION-docker.pkg.dev/YOUR_PROJECT_ID/YOUR_REPO_NAME/pcap-processor:latest
    cd ..
    ```
    *Example: `docker build -t europe-west8-docker.pkg.dev/gruppo-2/chronicle-sniffer/pcap-processor:latest .`*

3.  **Deploy Infrastructure with Terraform**:
    Navigate to the `terraform` directory.
    ```bash
    cd terraform
    cp terraform.tfvars.example terraform.tfvars
    ```
    Edit `terraform.tfvars` to set:
    *   `gcp_project_id`
    *   `gcp_region`
    *   `incoming_pcap_bucket_name` and `processed_udm_bucket_name` (must be globally unique)
    *   `processor_cloud_run_image` (the full URI of the image you just pushed, e.g., `europe-west8-docker.pkg.dev/YOUR_PROJECT_ID/YOUR_REPO_NAME/pcap-processor:latest`)
    *   `sniffer_image_uri` (e.g., `fillol/chronicle-sniffer:latest` if using the public Docker Hub image for the test VM, or your own Artifact Registry sniffer image)
    *   `ssh_source_ranges` for the test VM (e.g., `["YOUR_IP_ADDRESS/32"]`)

    Then, initialize and apply Terraform:
    ```bash
    terraform init -reconfigure
    terraform validate
    terraform plan -out=tfplan.out
    terraform apply tfplan.out
    ```
    Confirm with `yes`.

4.  **(Optional) Test VM & On-Premises Sniffer Setup**:
    Terraform will output instructions (`test_vm_sniffer_setup_instructions`) on how to:
    *   Generate an SA key for the sniffer (`generate_sniffer_key_command` output).
    *   SSH into the test VM.
    *   Copy the SA key to the VM.
    *   Configure and run the sniffer Docker container on the VM using Docker Compose.
    *   Alternatively, to run the sniffer locally (not on the test VM):
        ```bash
        # From the project root, after generating sniffer-key.json from terraform output
        mkdir -p sniffer/gcp-key
        cp ./sniffer-key.json sniffer/gcp-key/key.json # Copy the key generated by Terraform output
        cd sniffer
        cp .env.example .env
        # Edit .env with GCP_PROJECT_ID, INCOMING_BUCKET (from TF output), PUBSUB_TOPIC_ID (from TF output)
        docker compose build # If you modified the sniffer Dockerfile
        docker compose up -d
        ```

## Testing the Cloud-Side Pipeline (Simulating the Sniffer)

This section guides you through testing the GCP processing pipeline (Pub/Sub, Cloud Run, GCS) without running the actual on-premises sniffer. This is useful for validating the cloud components independently.

**Assumptions:**
1.  You have a sample `.pcap` file (e.g., `sample.pcap`) ready locally.
2.  Your `gcloud` CLI is authenticated with a user account that has at least `roles/pubsub.publisher` on the topic and `roles/storage.objectCreator` on the incoming GCS bucket.
3.  The Terraform infrastructure has been successfully deployed (`terraform apply` completed).

**Steps:**

1.  **Upload the Sample PCAP to the Incoming GCS Bucket:**
    Use `gsutil` to upload your test PCAP file. The filename in the bucket will be used in the Pub/Sub message.
    ```bash
    # Ensure gsutil uses the correct project
    gcloud config set project YOUR_PROJECT_ID 

    # Replace 'path/to/your/sample.pcap' and ensure the bucket name matches your terraform.tfvars
    gsutil cp path/to/your/sample.pcap gs://YOUR_INCOMING_PCAP_BUCKET_NAME/sample.pcap 
    ```
    *Example bucket name: `gs://chronicle-sniffer-incoming-pcaps/sample.pcap`*

2.  **Publish a Message to the Pub/Sub Topic:**
    The message payload should be the exact filename of the PCAP you uploaded to GCS.
    ```bash
    PCAP_FILENAME_IN_BUCKET="sample.pcap" # Must match the filename used in 'gsutil cp'
    TOPIC_ID=$(terraform output -raw pubsub_topic_id) # Get topic ID from Terraform output

    gcloud pubsub topics publish "${TOPIC_ID}" \
      --message "${PCAP_FILENAME_IN_BUCKET}"
    ```
    If successful, `gcloud` will output a `messageIds` field.

3.  **Verify Processing and Output:**
    *   **Cloud Run Logs**:
        *   Navigate to your Cloud Run service (`chronicle-sniffer-processor`) in the GCP Console.
        *   Go to the "Logs" tab.
        *   Look for logs indicating:
            *   Reception of the Pub/Sub message for `sample.pcap`.
            *   Download from the incoming GCS bucket.
            *   `tshark` conversion to JSON.
            *   `json2udm_cloud.py` script execution and UDM conversion.
            *   Upload of the UDM JSON to the processed GCS bucket.
            *   Successful completion message.
    *   **Processed UDM GCS Bucket**:
        *   Navigate to Cloud Storage in the GCP Console.
        *   Open your "processed-udm" bucket (e.g., `chronicle-sniffer-processed-udm`).
        *   You should find a file named `sample.udm.json` (or similar, based on your PCAP filename).
        *   Download and inspect this file to ensure it contains valid UDM JSON.

**Troubleshooting this Test:**
*   **Pub/Sub Message Not Delivered or Cloud Run Not Invoked**:
    *   Check the Pub/Sub subscription (`chronicle-sniffer-processor-sub`) for unacked messages or errors.
    *   Verify the push endpoint URL and OIDC authentication settings on the subscription.
    *   Ensure the Cloud Run service invoker permissions are correctly set (should be the `cloud_run_sa` if using OIDC, or `allUsers` if `allow_unauthenticated_invocations` was true during Terraform apply).
*   **Cloud Run Errors during Processing**:
    *   **File Not Found (404) from GCS**: Double-check that `PCAP_FILENAME_IN_BUCKET` in your `gcloud pubsub publish` command exactly matches the name of the file you uploaded with `gsutil`.
    *   **`tshark` or `json2udm_cloud.py` errors**: Examine the Cloud Run logs for detailed error messages or stack traces from these scripts. This might indicate issues with the PCAP file itself or bugs in the conversion logic.
    *   **Permission Errors (403) from GCS for Cloud Run SA**: Ensure the `cloud_run_sa` (`chronicle-sniffer-run-sa@...`) has the necessary roles (`storage.objectViewer` on incoming bucket, `storage.objectAdmin` or `storage.objectCreator` + delete on processed bucket, and `storage.legacyBucketReader` on both for startup checks). Terraform should manage this.

---
## Implementation Details

### Terraform Modules

*   **`gcs_buckets`**: Provisions two GCS buckets: one for incoming raw PCAP files and another for processed UDM JSON files. Configured with uniform bucket-level access, optional versioning, CMEK, and lifecycle rules for object deletion.
*   **`pubsub_topic`**: Creates the main Pub/Sub topic for PCAP file notifications and a corresponding dead-letter topic (DLQ). Configures a push subscription to the Cloud Run processor, utilizing OIDC for authenticated invocations and a dead-letter policy.
*   **`cloudrun_processor`**: Deploys the PCAP processor as a Cloud Run v2 service. Defines resource limits (CPU, memory), concurrency settings, startup and liveness probes, and injects necessary environment variables (bucket names, project ID).
*   **`test_generator_vm`**: (Optional) Creates a GCE instance to simulate an on-premises environment. Its startup script installs network tools like `tcpdump` and `tcpreplay`, and prepares the environment to run the sniffer Docker container.

### Sniffer Container (`sniffer/`)

*   **`Dockerfile`**: Based on `gcr.io/google.com/cloudsdktool/google-cloud-cli:alpine`, it installs `tshark`, `procps` (for `lsof`), and `iproute2`.
*   **`sniffer_entrypoint.sh`**:
    1.  Validates required environment variables (GCP Project ID, GCS Bucket, Pub/Sub Topic ID, SA Key Path).
    2.  Activates the provided Service Account using `gcloud auth activate-service-account`.
    3.  Automatically detects the primary active network interface (excluding loopback, docker, etc.).
    4.  Starts `tshark` in the background, configured to rotate capture files based on size or duration (env vars `ROTATE`, `LIMITS`).
    5.  Continuously monitors the capture directory for newly closed (rotated) PCAP files.
    6.  For each completed PCAP: uploads it to the specified GCS `INCOMING_BUCKET`, publishes the filename as a message to `PUBSUB_TOPIC_ID`, and then removes the local PCAP file.
    7.  Handles `SIGTERM` for graceful shutdown of `tshark`.

### Cloud Run Processor (`processor/`)

*   **`processor_app.py`**:
    *   A Flask web application serving as the endpoint for Pub/Sub push notifications.
    *   Initializes the Google Cloud Storage client, with a "lazy" verification of bucket accessibility to improve resilience against IAM propagation delays.
    *   Upon receiving a Pub/Sub message (containing a PCAP filename):
        1.  Downloads the specified PCAP file from the `INCOMING_BUCKET` to a temporary local directory.
        2.  Executes `tshark -T json` as a subprocess to convert the PCAP to a raw JSON representation.
        3.  Invokes the `json2udm_cloud.py` script (also as a subprocess) to transform the tshark JSON output into UDM JSON.
        4.  Uploads the resulting UDM JSON file to the `OUTPUT_BUCKET`.
    *   Returns HTTP `204 No Content` on successful processing.
    *   Returns appropriate HTTP `4xx` or `5xx` status codes for error conditions, facilitating Pub/Sub's retry and dead-lettering mechanisms. Includes specific handling for `google.api_core.exceptions.NotFound` when a PCAP file is not found in GCS.
*   **`json2udm_cloud.py`**:
    *   The core transformation logic, adapted for efficient cloud execution.
    *   **Streaming Processing**: Utilizes the `ijson` library to parse the (potentially very large) JSON output from `tshark` incrementally, packet by packet. This avoids loading the entire JSON into memory, preventing OOM errors in Cloud Run.
    *   **Robust Conversion**: For each packet:
        *   Extracts data from relevant layers (frame, Ethernet, IP, transport, DNS, HTTP, TLS, ARP).
        *   Maps these fields to a standardized UDM structure (metadata, principal, target, network, about, additional).
        *   Performs robust timestamp conversion to ISO 8601 UTC, with a fallback to the current processing time if the original timestamp is missing or malformed.
    *   **Error Handling per Packet**: If an error occurs while processing an individual packet, it generates a minimal UDM event containing error details and a snippet of the original packet, ensuring no data is entirely lost and aiding troubleshooting.
    *   Outputs a list of UDM event dictionaries, which is then written to a file by `processor_app.py`.
*   **`requirements.txt`**: Lists Python dependencies: `Flask`, `gunicorn`, `google-cloud-storage`, and `ijson`.

---
## Educational Value & Cloud-Native Principles

This project demonstrates several key concepts relevant to building scalable and reliable cloud services:

*   **Scalability & Decoupling**: Offloading intensive UDM conversion to serverless Cloud Run, triggered by Pub/Sub, allows the on-premises sniffer to remain lightweight. This design supports horizontal scaling of the processing layer independently of the capture points.
*   **Infrastructure as Code (IaC)**: Using Terraform with modular design ensures consistent, repeatable, and version-controlled infrastructure deployments.
*   **Managed Services**: Leveraging GCP's managed services (GCS, Pub/Sub, Cloud Run, IAM) reduces operational overhead and enhances reliability.
*   **Event-Driven Architecture**: The Pub/Sub message queue decouples the sniffer from the processor, improving resilience and allowing components to evolve independently.
*   **Security**: OIDC for secure, token-based authentication between Pub/Sub and Cloud Run, and IAM least-privilege for service accounts.
*   **Observability**: Integration with Cloud Logging and Cloud Monitoring for operational insight.

## Security Considerations

*   **Least-Privilege IAM**: Service Accounts for the sniffer (on-prem/VM) and the Cloud Run processor are granted only the necessary permissions for their tasks (e.g., GCS object creation/reading, Pub/Sub publishing, Cloud Run invocation).
*   **OIDC-Secured Cloud Run Invocation**: The Pub/Sub push subscription uses OIDC tokens to securely invoke the Cloud Run processor, ensuring that only legitimate Pub/Sub messages from the configured topic can trigger the service.
*   **Service Account Key Management**: For the on-premises sniffer, the SA key is intended to be mounted securely into the Docker container. Best practices for key rotation and restricted access to the key file should be followed.
*   **Firewall Rules**: The Terraform configuration for the optional test VM includes firewall rules that restrict SSH access to specified source IP ranges.
*   **GCS Bucket Security**: Buckets are configured with Uniform Bucket-Level Access (UBLA), and public access is prevented. Optional CMEK can be configured for an additional layer of encryption control.


## Maintenance & Troubleshooting

*   **Updating the Processor**:
    1.  Modify `processor_app.py` or `json2udm_cloud.py`.
    2.  Rebuild the Docker image (e.g., `docker build -t ... ./processor`).
    3.  Push the new image to Artifact Registry.
    4.  Update the `processor_cloud_run_image` variable in `terraform.tfvars` if you use a new tag.
    5.  Run `terraform apply`. Alternatively, manually deploy a new revision in the Cloud Run console pointing to the new image tag.
*   **Updating the Sniffer**:
    1.  Modify `sniffer_entrypoint.sh` or the sniffer `Dockerfile`.
    2.  Rebuild the sniffer Docker image (e.g., `docker compose build sniffer` if using Docker Compose locally, or `docker build ... ./sniffer`).
    3.  If using a private registry, push the image.
    4.  Update the image reference on the host running the sniffer (e.g., in `docker-compose.yml` or Kubernetes deployment) and restart the sniffer container.
*   **Scaling**:
    *   **Cloud Run Processor**: Adjust `cloud_run_memory`, `cloud_run_cpu`, and `max_instance_count` (in `template.scaling` within `terraform/modules/cloudrun_processor/main.tf`, not directly exposed as a variable in your current setup) via Terraform for higher throughput.
    *   **Pub/Sub**: Modify subscription retry policies (ack deadline, backoff durations) in `terraform/main.tf` if needed.
*   **Common Issues & Debugging**:
    *   **Sniffer not uploading/publishing**: Check sniffer container logs (`docker logs <container_name>`). Verify SA key validity and permissions (`storage.objectCreator` on incoming bucket, `pubsub.publisher` on the topic - *note: publisher permission for sniffer_sa is currently commented out in main.tf, assuming manual setup or user with rights runs sniffer*).
    *   **Pub/Sub messages in DLQ or high unacked count**: Inspect Cloud Run processor logs for errors. This usually points to issues in the `processor_app.py` or `json2udm_cloud.py` (e.g., PCAP/JSON parsing errors, GCS permission issues for the Cloud Run SA, OOM errors).
    *   **UDM Conversion Errors**: Test `json2udm_cloud.py` locally with the problematic `tshark`-generated JSON file to isolate issues. Enable debug logging.
    *   **Terraform Apply Failures**: Carefully read Terraform error messages. Validate `terraform.tfvars` against `variables.tf`. Ensure your `gcloud` user has permissions to create all resources defined.
    *   **Cloud Run Startup Failures**: Check Cloud Run revision logs for Python tracebacks or container startup issues. Ensure `requirements.txt` is complete and the `CMD` in the processor `Dockerfile` is correct.

---
## License
This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.