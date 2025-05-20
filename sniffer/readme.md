# [Chronicle-sniffer](https://hub.docker.com/r/fillol/chronicle-sniffer)
*A SecOps lens on the sensitive heart of your business*

## Overview

The **sniffer** container is a core component of the Chronicle-Sniffer pipeline. It's designed to run on an edge device, an on-premises server, or the provided test VM on GCP. Its primary functions are:
*   Capture live network traffic from a specified (or auto-detected) network interface using `tshark`.
*   Automatically rotate packet capture (`.pcap` or `.pcapng`) files based on size or duration.
*   Upload each completed capture file to a designated Google Cloud Storage (GCS) bucket.
*   Publish a notification (the filename of the uploaded PCAP) to a Google Cloud Pub/Sub topic, triggering downstream processing.

It's built for continuous, unattended operation.

## Features

*   **Continuous Capture & Rotation**: Leverages `tshark`'s ring buffer capabilities. Default rotation is every 10MB or 60 seconds.
*   **GCS Upload**: Securely uploads `.pcap*` files to your GCS bucket using `gcloud storage`.
*   **Pub/Sub Notifications**: Informs a Pub/Sub topic about new uploads for event-driven processing.
*   **Auto-Detect Network Interface**: Intelligently selects an active, non-virtual network interface if one isn't explicitly specified.
*   **Lightweight & Secure**: Based on a minimal Alpine image with `gcloud` and `tshark`. Service Account key is mounted read-only.
*   **Configurable**: Most operational parameters (GCP project, bucket, topic, sniffer ID, rotation settings) are configurable via environment variables.
*   **Heartbeat & Status Logging**: Provides logs for operational monitoring, including `tshark` status.

## Local Development & Testing with Docker Compose

This setup is ideal for testing the sniffer's functionality on your local machine.

**Prerequisites:**
*   Docker and Docker Compose installed.
*   A Google Cloud Platform Service Account key JSON file with permissions to write to a GCS bucket and (eventually) publish to a Pub/Sub topic.
*   A `.env` file configured with your GCP details.

**Steps to run locally (assuming you are in the `Chronicle-Sniffer/sniffer/` directory):**

1.  **Prepare Environment File:**
    Copy `.env.example` to `.env`:
    ```bash
    cp .env.example .env
    ```
    Edit `.env` with your actual values:
    *   `GCP_PROJECT_ID`: Your GCP project ID.
    *   `INCOMING_BUCKET`: The GCS bucket name for PCAP uploads (from Terraform output).
    *   `PUBSUB_TOPIC_ID`: The full Pub/Sub topic ID (e.g., `projects/your-project/topics/your-topic-name`, from Terraform output).
    *   `SNIFFER_ID`: A unique name for this local sniffer instance (e.g., "local-dev-sniffer").
    *   (Optional) `ROTATE`: Customize tshark rotation, e.g., `ROTATE="-b filesize:5120 -b duration:30"`.

2.  **Prepare Service Account Key:**
    *   Create a subdirectory named `gcp-key`:
        ```bash
        mkdir -p gcp-key
        ```
    *   Place your downloaded GCP Service Account JSON key file into this `gcp-key` directory and ensure it's named `key.json`.
        *Example: `mv /path/to/your-downloaded-key.json ./gcp-key/key.json`*

3.  **(Optional) Prepare Local Captures Directory:**
    If you want to see the generated PCAP files on your host machine (they are also stored inside the container's volume before upload):
    ```bash
    mkdir -p captures
    ```
    The `compose.yml` maps this `captures` directory to `/app/captures` inside the container.

4.  **Build and Run:**
    ```bash
    docker-compose up --build -d
    ```
    *   `--build` is only strictly needed the first time or if you change `Dockerfile` or `sniffer_entrypoint.sh`.
    *   `-d` runs the container in detached mode (in the background).

5.  **View Logs:**
    ```bash
    docker-compose logs -f sniffer
    ```
    (The service name in `compose.yml` is `sniffer`, but the `container_name` is `chronicle-sniffer-instance`. `docker-compose logs -f chronicle-sniffer-instance` might also work or just `docker logs chronicle-sniffer-instance -f`).
    *Correction: `docker-compose logs -f sniffer` is correct as `sniffer` is the service name in `compose.yml`.*

6.  **Generate Traffic:**
    Generate some network traffic on your host that the sniffer can capture (depending on the interface it chooses).

7.  **Stop and Remove:**
    ```bash
    docker-compose down
    ```
    This stops and removes the container. Add `-v` if you want to remove the named volume for captures (if any was implicitly created by Docker beyond the bind mount).

## Configuration (Environment Variables via `.env` file)

The sniffer container is configured using environment variables, typically supplied via an `.env` file when using Docker Compose.

| Variable          | Description                                                                 | Default in Entrypoint Script |
|-------------------|-----------------------------------------------------------------------------|------------------------------|
| `GCP_PROJECT_ID`  | **Required.** Your Google Cloud project ID.                                   | -                            |
| `INCOMING_BUCKET` | **Required.** Target GCS bucket name (without `gs://`).                       | -                            |
| `PUBSUB_TOPIC_ID` | **Required.** Full Pub/Sub topic ID (e.g., `projects/proj/topics/topic`).   | -                            |
| `SNIFFER_ID`      | **Required.** Unique identifier for this sniffer instance.                  | `unknown-sniffer`            |
| `GCP_KEY_FILE`    | Path *inside the container* to the SA JSON key.                             | `/app/gcp-key/key.json`      |
| `ROTATE`          | `tshark` capture rotation options.                                          | `-b filesize:10240 -b duration:60` (10MB or 60s) |
| `LIMITS`          | Optional additional `tshark` filters or limits (e.g., `-c <packet_count>`). | (empty)                      |
| `INTERFACE`       | (Advanced) Manually specify network interface (e.g., `eth1`). Auto-detected if empty. | (empty)                   |

Ensure all **Required** variables are set.

## Deployment on Test VM (GCP)

For testing the full pipeline on GCP, a test VM is provisioned by Terraform. The `startup_script_vm.sh` on the VM prepares a similar Docker Compose setup in `/opt/sniffer_env/`.
The key differences for the VM setup are:
*   The `docker-compose.yml` on the VM uses the specific `image` URI pulled from `var.sniffer_image_uri` (no `build` step).
*   A `docker-compose.override.yml` is generated to correctly map the SA key from `/opt/gcp_sa_keys/sniffer/key.json` on the VM host.
*   The user needs to `scp` the `sniffer-key.json` (generated via Terraform output) to `/opt/gcp_sa_keys/sniffer/key.json` on the VM.
*   Docker Compose commands are run from `/opt/sniffer_env/` on the VM (e.g., `sudo docker-compose up -d`).

Refer to the `test_vm_sniffer_setup_instructions` output from `terraform apply` for detailed steps.

## Security Notes

*   The Service Account key (`key.json`) is sensitive. Manage it securely. It's mounted read-only into the container.
*   The container runs with `network_mode: "host"` and capabilities `NET_ADMIN`, `NET_RAW`, which are necessary for packet capture but grant significant network access. Run in trusted environments.