# [Chronicle-sniffer](https://hub.docker.com/r/fillol/chronicle-sniffer)
*A SecOps lens on the sensitive heart of your businessy*

## Overview

The **sniffer** container captures live network packets with **tshark**, automatically rotates and stores `.pcap` files, uploads each completed capture to Google Cloud Storage, and publishes a notification to a Pub/Sub topic. Ideal for cloud environments where continuous traffic monitoring, centralized storage, and event-driven pipelines are required—no manual intervention needed.

## Features

* **Continuous Capture & Rotation**
  Automatically rotate capture files by size or time (default: 10 MB or 60 s).
* **Seamless GCS Upload**
  Uses `gcloud storage cp` to push each completed `.pcap` into your specified bucket.
* **Pub/Sub Notifications**
  Publishes the filename on a Google Cloud Pub/Sub topic for downstream processing.
* **Auto-Detect Interface**
  Selects the first active network interface (“up”), excluding loopback and virtual adapters.
* **Lightweight Base**
  Built on a slim Alpine (or Debian-slim) image to minimize footprint and attack surface.

## Usage

```bash
docker run -d \
  -e GCP_PROJECT_ID=your-project \
  -e INCOMING_BUCKET=your-bucket \
  -e PUBSUB_TOPIC_ID=projects/your-project/topics/your-topic \
  -v /path/to/key.json:/app/gcp-key/key.json:ro \
  your-org/sniffer:latest
```

1. **Quick start**: just set your GCP project, bucket, and Pub/Sub topic via environment variables.
2. **Read-only key**: mount your service account JSON in read-only mode (`:ro`) under `/app/gcp-key/key.json`.
3. **Transparent logging**: captures, uploads, and publication steps are logged to stdout.

## Configuration (Environment Variables)

| Variable          | Description                                                            |
| ----------------- | ---------------------------------------------------------------------- |
| `GCP_PROJECT_ID`  | Your Google Cloud project ID, used for all `gcloud` commands.          |
| `INCOMING_BUCKET` | Target GCS bucket name (without the `gs://` prefix).                   |
| `PUBSUB_TOPIC_ID` | Full Pub/Sub topic path (`projects/<project-id>/topics/<topic-name>`). |
| `GCP_KEY_FILE`    | Path to the service account JSON key (mount externally for security).  |
| `ROTATE`          | Capture rotation options (e.g. `-b filesize:10240 -b duration:60`).    |
| `LIMITS`          | Optional additional `tshark` filters or limits.                        |

All variables must be set for the container to run correctly.

## Best Practices

* **Official Base Images**
  Use Alpine or Debian-slim to leverage official security patches and reduce vulnerabilities.
* **Multi-Stage Builds**
  Separate build and runtime stages to minimize final image size.
* **`.dockerignore`**
  Exclude unnecessary files (logs, development artifacts) to speed up builds and shrink contexts.
* **Automated Scanning**
  Integrate container scanners (e.g., Docker Content Trust or third-party tools) into your CI/CD pipeline.
* **Semantic Tagging**
  Employ semantic version tags (e.g., `v1.2.3`) instead of `latest` for predictable deployments and rollbacks.