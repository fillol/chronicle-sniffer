# Chronicle-Sniffer  
<p align="left">
  <a href="https://cloud.google.com/" target="_blank"><img src="https://img.shields.io/badge/GCP-Google_Cloud-4285F4?style=flat&logo=google-cloud" alt="GCP"></a>
  <a href="https://www.terraform.io/" target="_blank"><img src="https://img.shields.io/badge/Terraform-7B42BC?style=flat&logo=terraform" alt="Terraform"></a>
  <a href="https://www.docker.com/" target="_blank"><img src="https://img.shields.io/badge/Docker-2496ED?style=flat&logo=docker&logoColor=white" alt="Docker"></a>
  <a href="https://www.python.org/" target="_blank"><img src="https://img.shields.io/badge/Python-3776AB?style=flat&logo=python&logoColor=white" alt="Python"></a>
  <a href="https://www.wireshark.org/docs/man-pages/tshark.html" target="_blank"><img src="https://img.shields.io/badge/TShark-1679A7?style=flat&logo=wireshark&logoColor=white" alt="TShark"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/fillol/Chronicle-Sniffer?style=flat" alt="Licenza: MIT"></a>
  <a href="https://hub.docker.com/r/fillol/chronicle-sniffer" target="_blank"><img src="https://img.shields.io/badge/Docker_Hub-fillol%2Fchronicle--sniffer-0094D6?style=flat&logo=docker" alt="Docker Hub: fillol/chronicle-sniffer"></a>
</p>

A Scalable Wireshark-to-SecOps Pipeline on Google Cloud Platform  

**Author:** [Filippo Lucchesi](https://github.com/fillol)  
**Course:** [Scalable and Reliable Services](https://www.unibo.it/en/study/course-units-transferable-skills-moocs/course-unit-catalogue/course-unit/2024/472686), [University of Bologna](https://www.unibo.it)  
**Evolution of:** [Wireshark-to-Chronicle-Pipeline (Cybersecurity Projects 2024)](https://github.com/fillol/Wireshark-to-Chronicle-Pipeline)  

This project implements a robust, scalable, and event-driven pipeline to capture network traffic using `tshark`, process it, and transform it into the Unified Data Model (UDM) for security analytics, all orchestrated on Google Cloud Platform (GCP) using Terraform. It evolves from an initial local processing concept into a cloud-native solution designed for enhanced reliability and scalability.

## Key Features & Enhancements

*   **Hybrid Capture Model**: A Dockerized `tshark` sniffer designed for on-premises or edge deployment handles initial packet capture, automatically rotating PCAP files (supporting `.pcap` and `.pcapng`), uploading them to Google Cloud Storage (GCS), and notifying a Pub/Sub topic.
*   **Serverless, Scalable Processing**: A GCP Cloud Run service acts as a serverless processor, triggered by Pub/Sub messages, to manage the demanding PCAP-to-UDM transformation.
*   **Optimized Core Transformation (`json2udm_cloud.py`)**: The central Python script, originally designed for local batch processing, has been significantly re-engineered. It now employs **streaming JSON parsing (`ijson`)** to handle potentially massive `tshark` outputs efficiently within Cloud Run's memory constraints, mapping raw packet data to UDM. This is the analytical heart of the project.
*   **Resilient and Decoupled Architecture**: Leverages a Pub/Sub-driven workflow for loose coupling between capture and processing. Includes dead-letter queue (DLQ) support for failed messages, Cloud Run health probes for service reliability, and robust error handling within the processing logic.
*   **Infrastructure as Code (IaC)**: The entire GCP infrastructure is managed by Terraform, promoting repeatability, version control, and automated provisioning.
*   **Minimal On-Premises Footprint**: All heavy computation (JSON parsing, UDM mapping) is offloaded to the cloud, requiring minimal resources on the capture (sniffer) side.
*   **Secure by Design**: Implements IAM least-privilege principles for service accounts, OIDC-authenticated Cloud Run invocations from Pub/Sub, and secure SA key management for the on-premises sniffer.
*   **Observable System**: Integrates with Cloud Logging for structured, centralized application and service logs. Leverages Cloud Monitoring with a comprehensive, custom operational dashboard defined as code (IaC) via Terraform, providing deep insights into pipeline health, performance, and error rates. Key performance indicators (KPIs) are tracked through numerous Log-Based Metrics.

---

## Table of Contents

- [Key Features & Enhancements](#key-features--enhancements)
- [Architecture Overview](#architecture-overview)
- [From Local Batch to Cloud-Native Streaming](#from-local-batch-to-cloud-native-streaming)
- [Repository Layout](#repository-layout)
- [Implementation Details](#implementation-details)
  - [Terraform Modules](#terraform-modules)
  - [Sniffer Container (`sniffer/`)](#sniffer-container-sniffer)
  - [Cloud Run Processor (`processor/`)](#cloud-run-processor-processor)
  - [Observable System: Logging, Metrics, and Dashboard](#observable-system-logging-metrics-and-dashboard)
- [How to Use](#how-to-use)
  - [Prerequisites](#prerequisites)
  - [Environment Setup](#environment-setup)
  - [Quickstart Deployment](#quickstart-deployment)
- [Educational Value & Cloud-Native Principles](#educational-value--cloud-native-principles)
- [Security Considerations](#security-considerations)
- [Maintenance & Troubleshooting](#maintenance--troubleshooting)

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
    *   Key service metrics (Cloud Run invocations, latency, errors; Pub/Sub message counts; GCS operations) and detailed application-level metrics (e.g., PCAP processing stages, UDM conversion details) are available in Cloud Monitoring, primarily through a dedicated operational dashboard.

## From Local Batch to Cloud-Native Streaming

This project originated from a [Cybersecurity course project](https://github.com/fillol/Wireshark-to-Chronicle-Pipeline) focused on local PCAP processing. The initial `json2udm.py` script (included in the repository for reference) was designed to:
*   Load an entire `tshark`-generated JSON file into memory.
*   Iterate through the parsed packets.
*   Handle local file system operations for input and output, including splitting large UDM outputs.

**Key improvements in `json2udm_cloud.py` for this "Scalable and Reliable Services" project:**
*   **Memory Efficiency**: The most significant change is the adoption of `ijson` for streaming JSON. This allows the script to process massive `tshark` JSON outputs packet by packet, drastically reducing memory footprint and making it suitable for resource-constrained environments like Cloud Run. The original `json.loads()` on a multi-gigabyte JSON file would lead to OOM errors.
*   **Robustness**: Enhanced error handling for individual packets. Instead of potentially skipping packets or failing entirely on malformed data, the script now attempts to create a minimal UDM event even for problematic packets, often including error details. Timestamp conversion is also more robust, with fallbacks.
*   **Cloud Environment Focus**: Removal of local file system concerns like multi-file output splitting. The script now produces a single UDM JSON output stream, which the `processor_app.py` then uploads to GCS.
*   **UDM Alignment**: The UDM structure produced has been refined to more closely align with common UDM schemas (e.g., Chronicle UDM), featuring distinct `metadata`, `principal`, `target`, and `network` sections.

These adaptations were crucial to transition the core logic from a local, batch-oriented tool to a scalable, cloud-native component.

---

## Repository Layout

```plaintext
Chronicle-Sniffer/
├── terraform/                      # Terraform IaC modules and configurations
│   ├── modules/
│   │   ├── gcs_buckets/            # Manages GCS buckets
│   │   ├── pubsub_topic/           # Manages Pub/Sub topic and DLQ
│   │   ├── cloudrun_processor/     # Manages Cloud Run processor service
│   │   └── test_generator_vm/      # Optional VM for on-prem simulation
│   │       └── startup_script_vm.sh
│   ├── dashboards/
│   │   └── main_operational_dashboard.json # Dashboard definition
│   ├── provider.tf
│   ├── variables.tf
│   ├── main.tf                     # Main Terraform configuration
│   ├── outputs.tf
│   └── terraform.tfvars.example    # Example variables for Terraform
├── sniffer/                        # On-Premises/Edge Sniffer component
│   ├── Dockerfile                  # Dockerfile for the sniffer
│   ├── sniffer_entrypoint.sh       # Entrypoint script for capture and upload
│   ├── compose.yml                 # Docker Compose for local sniffer testing
│   ├── .env.example                # Environment variables for sniffer example
│   └── readme.md                   # Sniffer-specific README
├── processor/                      # Cloud Run Processor component
│   ├── Dockerfile                  # Dockerfile for the processor
│   ├── processor_app.py            # Flask app orchestrating the processing
│   ├── json2udm_cloud.py           # Core PCAP JSON to UDM transformation script (streaming version)
│   └── requirements.txt            # Python dependencies for the processor
├── LICENSE                         # MIT License
└── readme.md                       # This file (main project README)
```

## Implementation Details

### Terraform Modules

*   **`gcs_buckets`**: Provisions two GCS buckets: one for incoming raw PCAP files and another for processed UDM JSON files. Configured with uniform bucket-level access, optional versioning, CMEK, and lifecycle rules for object deletion.
*   **`pubsub_topic`**: Creates the main Pub/Sub topic for PCAP file notifications and a corresponding dead-letter topic (DLQ). Configures a push subscription to the Cloud Run processor, utilizing OIDC for authenticated invocations and a dead-letter policy.
*   **`cloudrun_processor`**: Deploys the PCAP processor as a Cloud Run v2 service. Defines resource limits (CPU, memory), concurrency settings, startup and liveness probes, and injects necessary environment variables (bucket names, project ID).
*   **`test_generator_vm`**: (Optional) Creates a GCE instance to simulate an on-premises environment. Its startup script installs network tools and prepares the environment to run the sniffer Docker container.

### Sniffer Container (`sniffer/`)

*   **`Dockerfile`**: Based on `gcr.io/google.com/cloudsdktool/google-cloud-cli:alpine`, it installs `tshark`, `procps` (for `lsof`), and `iproute2`.
*   **`sniffer_entrypoint.sh`**:
    1.  Validates required environment variables (GCP Project ID, GCS Bucket, Pub/Sub Topic ID, SA Key Path, Sniffer ID).
    2.  Activates the provided Service Account using `gcloud auth activate-service-account`.
    3.  Automatically detects the primary active network interface (excluding loopback, docker, etc.).
    4.  Starts `tshark` in the background, configured to rotate capture files based on size or duration (env vars `ROTATE`, `LIMITS`).
    5.  Includes a background heartbeat function that logs `TSHARK_STATUS` (running/stopped) for monitoring.
    6.  Continuously monitors the capture directory for newly closed (rotated) PCAP files (matching `*.pcap*` to include `.pcapng` format).
    7.  For each completed PCAP: logs its size, uploads it to the specified GCS `INCOMING_BUCKET`, publishes the filename as a message to `PUBSUB_TOPIC_ID`, and then removes the local PCAP file.
    8.  Handles `SIGTERM` and `SIGINT` for graceful shutdown of `tshark` and the heartbeat process.

### Cloud Run Processor (`processor/`)

*   **`processor_app.py`**:
    *   A Flask web application serving as the endpoint for Pub/Sub push notifications.
    *   Initializes the Google Cloud Storage client, with a "lazy" verification of bucket accessibility to improve resilience against IAM propagation delays.
    *   Upon receiving a Pub/Sub message (containing a PCAP filename):
        1.  Downloads the specified PCAP file from the `INCOMING_BUCKET` to a temporary local directory.
        2.  Executes `tshark -T json` as a subprocess to convert the PCAP to a raw JSON representation.
        3.  Invokes the `json2udm_cloud.py` script (also as a subprocess) to transform the tshark JSON output into UDM JSON.
        4.  Uploads the resulting UDM JSON file to the `OUTPUT_BUCKET`.
    *   Logs key events for metrics (download complete, tshark conversion successful, UDM conversion script output, upload complete, processing duration).
    *   Returns HTTP `204 No Content` on successful processing.
    *   Returns appropriate HTTP `4xx` or `5xx` status codes for error conditions, facilitating Pub/Sub's retry and dead-lettering mechanisms.
*   **`json2udm_cloud.py`**:
    *   The core transformation logic, adapted for efficient cloud execution.
    *   **Streaming Processing**: Utilizes the `ijson` library to parse the (potentially very large) JSON output from `tshark` incrementally, packet by packet. This avoids loading the entire JSON into memory, preventing OOM errors in Cloud Run.
    *   **Robust Conversion**: For each packet, extracts data from relevant layers and maps them to a standardized UDM structure. Performs robust timestamp conversion to ISO 8601 UTC, with a fallback to the current processing time if the original timestamp is missing or malformed.
    *   **Error Handling per Packet**: If an error occurs while processing an individual packet, it generates a minimal UDM event containing error details.
    *   Logs `UDM_PACKETS_PROCESSED` and `UDM_PACKET_ERRORS` counts per input file for metrics.
    *   Outputs a list of UDM event dictionaries.
*   **`requirements.txt`**: Lists Python dependencies: `Flask`, `gunicorn`, `google-cloud-storage`, and `ijson`.

### Observable System: Logging, Metrics, and Dashboard

The pipeline is designed for comprehensive observability:

*   **Cloud Logging**: Both the on-premises sniffer (`sniffer_entrypoint.sh`) and the Cloud Run processor (`processor_app.py`, `json2udm_cloud.py`) generate detailed logs. These logs are structured to include crucial information like sniffer IDs, filenames, processing stages, and error messages, facilitating debugging and operational monitoring. All logs are centralized in Google Cloud Logging.

*   **Log-Based Metrics (LBMs)**: The Terraform configuration in `terraform/main.tf` defines a rich set of Log-Based Metrics. These metrics convert specific log patterns into quantifiable time-series data in Cloud Monitoring. Examples include:
    *   **Sniffer Metrics**: Heartbeat counts, PCAP files uploaded, PCAP file sizes (distribution), GCS upload errors, Pub/Sub publish errors. (Note: `sniffer_tshark_status_running_count` was also defined for TShark status).
    *   **Processor Metrics**: PCAP download successes/failures, TShark conversion successes/errors, UDM packets processed (distribution, per file), UDM packet processing errors (distribution, per file), UDM file upload successes, and end-to-end processing latency (distribution).
    *   These LBMs form the backbone of the operational dashboard.

*   **Operational Dashboard (`terraform/dashboards/main_operational_dashboard.json`)**:
    A key deliverable of this project is a comprehensive operational dashboard, defined as Infrastructure as Code and deployed by Terraform. This dashboard, configured using Monitoring Query Language (MQL), provides a centralized view of the entire pipeline's health and performance.

    **Dashboard Structure and Key Sections:**

    The dashboard (as per the latest JSON version provided by the user) is organized into logical sections with a 4-column layout:

    1.  **🛰️ Sniffer & Edge Overview**: Focuses on the health and output of the on-premises/edge sniffer components.
        *   *(No Scorecards in the user-provided final version)*
        *   **Time Series Charts**: Detailed views of sniffer heartbeats (by ID and interface), PCAP file upload rates (by sniffer ID), average PCAP file sizes (by sniffer ID, calculated via MQL from distribution), and error counts for PCAP uploads.

    2.  **📣 Cloud Pub/Sub**: Monitors the health of the message queue.
        *   **Time Series Charts**: Tracks unacknowledged messages, DLQ messages, and Pub/Sub publish errors originating from the sniffers.

    3.  **⚙️ Cloud Processor**: Provides insights into the Cloud Run processing service.
        *   **Time Series Charts**: Metrics for PCAP download success/not-found, TShark conversion success/errors, UDM upload success rates.
        *   Standard Cloud Run metrics like successful request rates.

    4.  **(Integrated with Processor Section)** **UDM Conversion & Latency**:
        *   **Time Series Charts**: UDM packet processed rates and UDM packet-level error rates (grouped by filename, leveraging MQL on distribution metrics).
        *   Average PCAP processing latency (calculated via MQL from distribution) and 95th percentile latency.

    **Query Language**: The dashboard exclusively uses **MQL (Monitoring Query Language)** for querying both standard GCP metrics and the custom Log-Based Metrics. This was adopted for its direct and robust integration with Cloud Monitoring metric types, especially for LBMs and for performing complex aggregations or calculations directly in the query.

    **Customization and Iteration**: The dashboard's JSON definition allows for precise control over its appearance and a version-controlled approach to its evolution.

---

## How to Use

### Prerequisites

*   A Google Cloud Platform (GCP) account with billing enabled.
*   Required GCP APIs enabled in your project: Cloud Run, Pub/Sub, Cloud Storage, IAM, Artifact Registry, Compute Engine (if using the test VM), Cloud Monitoring API.
*   `gcloud` CLI installed and authenticated.
*   Terraform (>=1.1.0) installed.
*   Docker installed (for building images and optionally running the sniffer locally).
*   An Artifact Registry Docker repository (e.g., `chronicle-sniffer`) in your GCP project and region (if you intend to host your custom-built images there).

### Environment Setup

Before deploying, authenticate `gcloud` and configure Docker for Artifact Registry (if using private images from AR):

```bash
# Log in to your Google account (this will open a browser window)
gcloud auth login

# Set your default GCP project
gcloud config set project YOUR_PROJECT_ID

# Authenticate Application Default Credentials (used by Terraform and other tools)
gcloud auth application-default login

# Configure Docker to authenticate with Artifact Registry (if needed)
# Replace REGION with your Artifact Registry region (e.g., europe-west8)
gcloud auth configure-docker REGION-docker.pkg.dev
```

### Quickstart Deployment

1.  **Clone the Repository**:
    ```bash
    git clone https://github.com/fillol/Chronicle-Sniffer.git # Or your repo URL
    cd Chronicle-Sniffer
    ```

2.  **Build and Push the Processor Docker Image**:
    (Skip if using a pre-built public image for the processor)
    Navigate to the `processor` directory and build the image, then push it to your Artifact Registry.
    ```bash
    cd processor
    # Replace REGION, YOUR_PROJECT_ID, YOUR_REPO_NAME, and TAG accordingly
    docker build -t REGION-docker.pkg.dev/YOUR_PROJECT_ID/YOUR_REPO_NAME/pcap-processor:latest .
    docker push REGION-docker.pkg.dev/YOUR_PROJECT_ID/YOUR_REPO_NAME/pcap-processor:latest
    cd ..
    ```
    *Example: `docker build -t europe-west8-docker.pkg.dev/my-project/my-repo/pcap-processor:latest .`*

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
    *   `processor_cloud_run_image` (the full URI of the image for the processor, e.g., the one you just pushed or a public one)
    *   `sniffer_image_uri` (e.g., `fillol/chronicle-sniffer:latest` or your own Artifact Registry sniffer image if you built one)
    *   `ssh_source_ranges` for the test VM (e.g., `["YOUR_IP_ADDRESS/32"]`)

    Then, initialize and apply Terraform:
    ```bash
    terraform init -reconfigure
    terraform validate
    terraform plan -out=tfplan.out
    terraform apply tfplan.out
    ```
    Confirm with `yes`. This will also deploy the operational dashboard.

4.  **(Optional) Test VM & On-Premises Sniffer Setup**:
    Terraform will output `test_vm_sniffer_setup_instructions` on how to set up and run the sniffer on the provisioned test GCE VM. This involves generating an SA key, copying it to the VM, and then running `docker-compose` on the VM.

    To run the sniffer **locally using Docker Compose** (e.g., on your development machine, not the test VM):
    a.  Ensure you are in the project's root directory (`Chronicle-Sniffer/`).
    b.  Generate the sniffer Service Account key if you haven't already (from Terraform output `generate_sniffer_key_command`). This creates `./sniffer-key.json` in the root.
    c.  Navigate to the sniffer directory: `cd sniffer`
    d.  Create the key directory: `mkdir -p gcp-key`
    e.  Copy the generated key: `cp ../sniffer-key.json ./gcp-key/key.json` (This places the key from the project root into `sniffer/gcp-key/`)
    f.  Create and configure your `.env` file from `.env.example`: `cp .env.example .env`
        *   Edit `sniffer/.env` with your `GCP_PROJECT_ID`, `INCOMING_BUCKET` (from Terraform output), and `PUBSUB_TOPIC_ID` (from Terraform output, e.g., `projects/YOUR_PROJECT_ID/topics/YOUR_TOPIC_NAME`).
    g.  (Optional) Create a directory for local captures if you want them persisted on your host: `mkdir captures` (the `sniffer/compose.yml` maps this).
    h.  Build (if needed) and run the sniffer: `docker-compose up --build -d` (run this command from within the `sniffer/` directory).
    i.  To see logs: `docker-compose logs -f` (from within the `sniffer/` directory, or specify service name).
    j.  To stop: `docker-compose down` (from within the `sniffer/` directory).

---

## Educational Value & Cloud-Native Principles

This project demonstrates several key concepts relevant to building scalable and reliable cloud services:

*   **Scalability & Decoupling**: Offloading intensive UDM conversion to serverless Cloud Run, triggered by Pub/Sub, allows the on-premises sniffer to remain lightweight. This design supports horizontal scaling of the processing layer independently of the capture points.
*   **Infrastructure as Code (IaC)**: Using Terraform with modular design ensures consistent, repeatable, and version-controlled infrastructure deployments, including the monitoring dashboard.
*   **Managed Services**: Leveraging GCP's managed services (GCS, Pub/Sub, Cloud Run, IAM, Cloud Monitoring) reduces operational overhead and enhances reliability.
*   **Event-Driven Architecture**: The Pub/Sub message queue decouples the sniffer from the processor, improving resilience and allowing components to evolve independently.
*   **Security**: OIDC for secure, token-based authentication between Pub/Sub and Cloud Run, and IAM least-privilege for service accounts.
*   **Observability**: Deep integration with Cloud Logging and Cloud Monitoring, featuring custom metrics and a detailed operational dashboard for comprehensive system insight.

## Security Considerations

*   **Least-Privilege IAM**: Service Accounts for the sniffer (on-prem/VM) and the Cloud Run processor are granted only the necessary permissions for their tasks.
*   **OIDC-Secured Cloud Run Invocation**: The Pub/Sub push subscription uses OIDC tokens to securely invoke the Cloud Run processor, ensuring that only legitimate Pub/Sub messages from the configured topic can trigger the service.
*   **Service Account Key Management**: For the on-premises sniffer, the SA key is intended to be mounted securely into the Docker container. Best practices for key rotation and restricted access should be followed.
*   **Firewall Rules**: The Terraform configuration for the optional test VM includes firewall rules that restrict SSH access to specified source IP ranges.
*   **GCS Bucket Security**: Buckets are configured with Uniform Bucket-Level Access (UBLA), and public access is prevented. Optional CMEK can be configured for an additional layer of encryption control.

## Maintenance & Troubleshooting

*   **Updating the Processor**:
    1.  Modify `processor_app.py` or `json2udm_cloud.py`.
    2.  Rebuild the Docker image and push to Artifact Registry.
    3.  Update `processor_cloud_run_image` in `terraform.tfvars` if using a new tag.
    4.  Run `terraform apply`. Alternatively, manually deploy a new revision in the Cloud Run console pointing to the new image tag.
*   **Updating the Sniffer**:
    1.  Modify `sniffer_entrypoint.sh` or the sniffer `Dockerfile`.
    2.  Rebuild and push the sniffer Docker image (e.g., to Docker Hub or your Artifact Registry).
    3.  Update the image reference (`var.sniffer_image_uri` in `terraform.tfvars` if the test VM pulls it, and on any actual on-prem hosts) and restart the sniffer containers.
*   **Scaling**:
    *   **Cloud Run Processor**: Adjust `cloud_run_memory`, `cloud_run_cpu`, and `max_instance_count` (via Terraform or Cloud Run console) for desired throughput.
    *   **Pub/Sub**: Modify subscription retry policies if needed.
*   **Common Issues & Debugging**:
    *   **Sniffer not uploading/publishing**: Check sniffer container logs. Verify SA key validity and permissions (especially Pub/Sub publisher role for the sniffer's SA).
    *   **Pub/Sub messages in DLQ or high unacked count**: Inspect Cloud Run processor logs. This usually points to issues in the processing scripts or GCS permissions for the Cloud Run SA.
    *   **UDM Conversion Errors**: Examine `json2udm_cloud.py stderr` messages in Cloud Run logs. Test locally with problematic JSON if possible.
    *   **Terraform Apply Failures**: Read Terraform error messages. Validate `terraform.tfvars`. Ensure `gcloud` user has permissions to create/modify all resources.
    *   **Dashboard Widgets Empty/Erroring**:
        *   Verify Log-Based Metrics are correctly defined in `terraform/main.tf` and are active in Cloud Monitoring (Metrics Management).
        *   Check if logs matching the LBM filters are being generated by the sniffer or processor.
        *   Use Metrics Explorer in Cloud Monitoring to test the MQL queries or inspect the raw metric data for your custom LBMs.
        *   Ensure variable names in the dashboard JSON (`${cloud_run_processor_service_name}`, etc.) match those passed by the `templatefile` function in `terraform/main.tf`.
