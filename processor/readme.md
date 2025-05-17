# PCAP to UDM Processor for Cloud Run

This directory contains the components for a Cloud Run service that processes PCAP files into UDM (Unified Data Model) JSON format.

## Components

*   **`Dockerfile`**: Defines the Docker container image for the Cloud Run service. It includes Python, TShark, and necessary Python libraries.
*   **`processor_app.py`**: A Flask web application that:
    *   Listens for Pub/Sub notifications indicating new PCAP files in a GCS bucket.
    *   Downloads the PCAP file.
    *   Uses TShark to convert the PCAP to a structured JSON format.
    *   Invokes `json2udm_cloud.py` to transform the TShark JSON into UDM.
    *   Uploads the resulting UDM JSON to an output GCS bucket.
*   **`json2udm_cloud.py`**: A Python script responsible for converting the JSON output from TShark into the UDM format. It's designed for memory-efficient streaming of large JSON inputs.
*   **`requirements.txt`**: Lists Python dependencies (e.g., Flask, google-cloud-storage, ijson).

## Workflow

1.  A PCAP file is uploaded to a designated GCS input bucket.
2.  A Pub/Sub notification (triggered by the GCS upload) is sent to the `processor_app.py` endpoint running on Cloud Run.
3.  The application downloads the PCAP, processes it through TShark, then converts the output to UDM using `json2udm_cloud.py`.
4.  The final UDM JSON file is uploaded to a GCS output bucket.

## Deployment

This service is designed to be deployed as a container on Google Cloud Run, triggered by Pub/Sub events. Environment variables are used for configuration (e.g., bucket names).