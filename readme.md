# Chronicle-sniffer: a Wireshark-to-SecOps Pipeline on GCP

**Author:** [Filippo Lucchesi](https://github.com/fillol)  
**Course:** [Scalable and Reliable Services](https://www.unibo.it/en/study/course-units-transferable-skills-moocs/course-unit-catalogue/course-unit/2024/472686), [University of Bologna](https://www.unibo.it)  
**Based on:** [Wireshark-to-Chronicle-Pipeline](https://github.com/fillol/Wireshark-to-Chronicle-Pipeline)  

## Key Features

* **On‑Premises/Edge Sniffer**: Dockerized `tshark` capture with automatic PCAP rotation, upload to GCS, and Pub/Sub notification.
* **Serverless Processor**: Cloud Run service that orchestrates PCAP-to-UDM transformation.
* **Core Component (`json2udm_cloud.py`)**: Central Python script that maps raw `tshark` JSON into the Unified Data Model (UDM), forming the project’s analytical heart.
* **Scalable, Resilient Design**: Decoupled Pub/Sub-driven flow with dead-letter support, Cloud Run health probes, Terraform-managed IaC.
* **Full Cloud Offload**: Eliminates heavy client‑side computation; all parsing and enrichment occur server‑side for minimal on‑prem hardware requirements.
* **Secure and Observable**: IAM least‑privilege, OIDC‑authenticated Cloud Run, structured logging, and custom monitoring dashboard.

---

## Architecture Overview

A distributed, event‑driven pipeline leveraging GCP managed services:

1. **Capture & Upload**:

   * Sniffer container runs `tshark` on the selected network interface, rotating PCAPs by size/time.
   * Completed PCAPs are uploaded to GCS (`incoming-pcaps`), then Pub/Sub notification is published.
2. **Trigger & Process**:

   * Pub/Sub push subscription invokes the Cloud Run Processor (OIDC‑secured).
   * Processor downloads the PCAP, uses `tshark -T json`, then executes the **`json2udm_cloud.py`** script to emit UDM‑formatted JSON.
   * Resulting UDM events are stored in GCS (`processed-udm`).
3. **Error Handling & Observability**:

   * Failed deliveries route to a dead-letter topic after retry limits.
   * Logs flow into Cloud Logging; metrics into Cloud Monitoring; health checks enforce service reliability.


## Repository Layout

```plaintext
Chronicle-sniffer/
├── terraform/                      # Terraform IaC modules and configs
│   ├── modules/
│   │   ├── gcs_buckets/
│   │   ├── pubsub_topic/
│   │   ├── cloudrun_processor/
│   │   └── test_generator_vm/       # VM simulating on‑prem environment
│   │       └── startup.sh
│   ├── provider.tf
│   ├── variables.tf
│   ├── main.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── sniffer/                        # On‑Prem/Edge Sniffer
│   ├── Dockerfile
│   ├── sniffer_entrypoint.sh
│   ├── docker-compose.yml          # Local sniffer compose
│   └── .env.example                # Env vars template
├── processor/                      # Cloud Run Processor
│   ├── Dockerfile
│   ├── processor_app.py            # Flask endpoint for Pub/Sub
│   ├── json2udm_cloud.py           # Core UDM mapper
│   └── requirements.txt
├── LICENSE.md                      # MIT License
└── readme.md                       # This file
```

---

## Prerequisites

* GCP account with billing and required APIs (Cloud Run, Pub/Sub, Storage, IAM).
* `gcloud` CLI configured for project and Artifact Registry.
* Terraform (>=1.1.0).
* Docker for local sniffer image.
* Artifact Registry repository for processor image.

## Environment Setup

Before deploying, authenticate and configure your environment:

```bash
# Log in to your Google account
# (This will open a browser window)
gcloud auth login

# Set the default project
gcloud config set project YOUR_PROJECT_ID

# Authenticate Application Default Credentials for Terraform and other tools
gcloud auth application-default login

# Configure Docker to push/pull to Artifact Registry
# Replace REGION and PROJECT_ID accordingly
gcloud auth configure-docker REGION-docker.pkg.dev
```

## Quickstart

1. **Clone repository**:

   ```bash
   git clone https://github.com/fillol/wireshark-pipeline-hybrid.git
   cd wireshark-pipeline-hybrid
   ```
2. **Build & push processor image**:

   ```bash
   cd processor
   docker build -t REGION-docker.pkg.dev/PROJECT_ID/REPO/processor:TAG .
   docker push REGION-docker.pkg.dev/PROJECT_ID/REPO/processor:TAG
   ```
3. **Deploy infrastructure**:

   ```bash
   cd ../terraform
   cp terraform.tfvars.example terraform.tfvars
   # configure project, region, buckets, image URI, SSH CIDRs
   terraform init -reconfigure
   terraform plan -out=tfplan
   terraform apply tfplan
   ```
4. **Generate Sniffer SA key**:

   ```bash
   # use Terraform output
   cp key.json ../sniffer/gcp-key/
   ```
5. **Start sniffer**:

   ```bash
   cd ../sniffer
   cp .env.example .env
   # fill GCP_PROJECT_ID, INCOMING_BUCKET, PUBSUB_TOPIC_ID
   docker-compose up -d
   ```
6. **Validate pipelines**:

   * Monitor Cloud Run logs for processing events.
   * Check `processed-udm` bucket for UDM JSON files.
7. **Cleanup**:

   ```bash
   cd ../terraform
   terraform destroy
   cd ../sniffer
   docker-compose down
   rm gcp-key/key.json
   ```

---

## Educational Value

This project serves as a hands‑on exploration of key course topics:

* **Scalability & Distribution**: By offloading computation to serverless Cloud Run and decoupling via Pub/Sub, on‑prem devices only perform lightweight capture, simplifying client hardware and enabling horizontal scaling of processing.
* **Cloud-Native Best Practices**: Utilizes Terraform modules for repeatable IaC, GCP managed services for resilience, and OIDC for secure service integration.
* **Comprehensive GCP Toolchain**: Hands‑on with Cloud Storage, Pub/Sub, Cloud Run, Cloud Monitoring, Cloud Logging, IAM, and Artifact Registry.
* **Modular Design**: The core `json2udm_cloud.py` script embodies the transformation logic, making it reusable across different ingestion workflows.


## Test VM (On‑Prem Simulation)

The optional test VM replicates an on‑premises environment:

* Provisioned via Terraform (`test_generator_vm` module) with restrictive SSH rules (`ssh_source_ranges`).
* Runs `startup.sh` to install `tcpdump` and `tcpreplay`, preparing for traffic generation.
* Use `tcpreplay` to stream sample PCAPs to the sniffer for end‑to‑end validation.


## Logging & Monitoring

A dedicated dashboard tracks both operational and cost metrics:

* **Logs**: Structured JSON logs from sniffer containers and Cloud Run are centralized in Cloud Logging for traceability.
* **Metrics**: GCS operations, Pub/Sub backlog, Cloud Run invocations, error rates, and compute usage are visualized in Cloud Monitoring dashboards.
* **Billing Alerts**: Alerts configured for unusual cost spikes, ensuring the client maintains budgetary control.

---

## Implementation Details

### Terraform Modules

* **gcs\_buckets**: Incoming and processed buckets with versioning, uniform access, optional CMEK, and lifecycle rules.
* **pubsub\_topic**: Main and DLQ topics, push subscription with OIDC and dead‑letter policy.
* **cloudrun\_processor**: Cloud Run v2 service with resource limits, concurrency, probes, and environment variables.
* **test\_generator\_vm**: GCE instance simulating on‑prem, installs network tools on startup.

### Sniffer Container

* **Dockerfile**: `google/cloud-sdk:slim` base, installs `tshark`, `procps`, `iproute2`.
* **sniffer\_entrypoint.sh**:

  1. Validate env vars.
  2. Activate SA via `gcloud auth`.
  3. Auto-detect network interface.
  4. Run `tshark` with rotation (size/time).
  5. Monitor capture directory, upload closed PCAPs, publish Pub/Sub messages, delete local files.
  6. Graceful shutdown on SIGTERM.

### Cloud Run Processor

* **processor\_app.py**:

  * Flask endpoint for Pub/Sub push.
  * Downloads PCAP to temp directory, runs `tshark -T json`, calls `json2udm_cloud.py`, uploads UDM JSON.
  * Returns HTTP 204 on success; appropriate 4xx/5xx for Pub/Sub retry semantics.

* **json2udm\_cloud.py**:

  * Parses raw `tshark` JSON layers (frame, eth, ip, transport, application).
  * Maps to UDM schema (metadata, principal, target, network, about).
  * Converts timestamps to ISO8601 UTC.
  * Handles missing fields gracefully; logs extraction errors.
  * Emits newline‑delimited JSON array of UDM events.

---

## Security Considerations

* **Least-Privilege IAM** for sniffer and processor SAs.
* **OIDC‑Secured Cloud Run Invocation**.
* **Local SA Key Management** with rotation and restricted storage.
* **Firewall Rules** restricting SSH on test VM.
* **Bucket Policies**: Uniform access, no public ACLs, optional CMEK encryption.


## Maintenance & Troubleshooting

* **Processor Updates**: Rebuild/push image, update `processor_image_uri`, `terraform apply`.

* **Sniffer Updates**: Rebuild sniffer image, adjust `docker-compose.yml`, `docker-compose up`.

* **Scaling Notes**:

  * For high-throughput workloads, consider increasing Cloud Run memory/CPU, max instances (`max_instances`), or adjusting concurrency in the `cloudrun_processor` Terraform module.
  * Configure Pub/Sub retry settings (e.g., `maximum_backoff_duration`, `minimum_backoff_duration`) in Terraform for more robust error handling during peak load or transient errors.

* **Common Issues**:

  * No uploads: check sniffer logs and SA permissions.
  * Pub/Sub backlog: inspect Cloud Run logs; check DLQ.
  * Conversion errors: test `tshark` and UDM mapping locally.
  * Terraform failures: validate `terraform.tfvars` and inspect plan

---

## License

This project is licensed under the MIT License. See [LICENSE.md](LICENSE.md) for details.
