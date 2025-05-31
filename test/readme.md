# Test Directory - Chronicle-Sniffer

This directory contains sample files and artifacts useful for testing and understanding the basic functionality of the Chronicle-Sniffer pipeline, particularly the PCAP to UDM conversion process.

## Contents

1.  **`synflood_capture.pcap`**:
    *   A network capture file (`.pcap`) containing an example of SYN flood traffic.
    *   This traffic was generated using the `hping3` tool.
    *   It can be used as a test input for the pipeline, for instance, by manually uploading it to the input GCS bucket to simulate a file arrival from the sniffer.

2.  **`synflood_capture.udm.json`**:
    *   The result of converting the `synflood_capture.pcap` file into the Unified Data Model (UDM) format.
    *   This JSON file represents the expected output from the Cloud Run processing service when it processes the sample PCAP.
    *   It is useful for verifying correct field mapping and the general structure of the generated UDM events.

3.  **`gcp_conversion_log_snippet.png`**:
    *   A screenshot showing a snippet of logs from Google Cloud Logging.
    *   This snippet highlights key log messages 얼굴indicating a successful conversion of the test PCAP file (`synflood_capture.pcap`) through the Cloud Run processor service.
    *   It demonstrates that the pipeline can process the sample file and generate the expected UDM output in the GCP environment.
  
4.  **`broken_capture.pcap`**:
    *   A purposely corrupted network capture file (`.pcap`) designed to test pipeline resilience and logging.

## Purpose of these Test Files
*   **Quick Demonstration:** Offer a fast way to see an example of input (PCAP), output (UDM), and proof of successful cloud processing.
*   **Basic Integration Testing:** Allow users to test the pipeline flow by uploading the sample PCAP.
*   **Output Understanding:** Provide a concrete reference of the UDM format produced by the `json2udm.py` script for a specific type of traffic.

## In-depth Script Conversion Testing

It is important to note that these sample files are intended for a general validation of the pipeline and output format.

For **more detailed and in-depth testing specifically of the `json2udm_cloud.py` conversion script** (including unit tests, handling of various protocols, edge cases, and script performance), please refer to the original project from which this script evolved:

➡️ **[Wireshark-to-Chronicle-Pipeline (Cybersecurity Projects 2024)](https://github.com/fillol/Wireshark-to-Chronicle-Pipeline)**

That repository focused more extensively on the analysis and robustness of the transformation logic from TShark's JSON output to UDM.

---

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
        *   Navigate to your Cloud Run service (`chronicle-sniffer-processor` or similar, based on `var.base_name`) in the GCP Console.
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
        *   Open your "processed-udm" bucket (e.g., `chronicle-sniffer-processed-udm` or similar).
        *   You should find a file named `sample.udm.json` (or similar, based on your PCAP filename).
        *   Download and inspect this file to ensure it contains valid UDM JSON.

**Troubleshooting this Test:**
*   **Pub/Sub Message Not Delivered or Cloud Run Not Invoked**:
    *   Check the Pub/Sub subscription (e.g., `chronicle-sniffer-processor-sub`) for unacked messages or errors.
    *   Verify the push endpoint URL and OIDC authentication settings on the subscription.
    *   Ensure the Cloud Run service invoker permissions are correctly set (should be the `cloud_run_sa` if using OIDC, or `allUsers` if `allow_unauthenticated_invocations` was true during Terraform apply).
*   **Cloud Run Errors during Processing**:
    *   **File Not Found (404) from GCS**: Double-check that `PCAP_FILENAME_IN_BUCKET` in your `gcloud pubsub publish` command exactly matches the name of the file you uploaded with `gsutil`.
    *   **`tshark` or `json2udm_cloud.py` errors**: Examine the Cloud Run logs for detailed error messages or stack traces from these scripts. This might indicate issues with the PCAP file itself or bugs in the conversion logic.
    *   **Permission Errors (403) from GCS for Cloud Run SA**: Ensure the `cloud_run_sa` (e.g., `chronicle-sniffer-run-sa@...`) has the necessary roles (`storage.objectViewer` on incoming bucket, `storage.objectAdmin` or `storage.objectCreator` + delete on processed bucket, and `storage.legacyBucketReader` on both for startup checks). Terraform should manage this.
