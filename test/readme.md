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

## Purpose of these Test Files

These files are provided to:

*   **Quick Demonstration:** Offer a fast way to see an example of input (PCAP), output (UDM), and proof of successful cloud processing.
*   **Basic Integration Testing:** Allow users to test the pipeline flow by uploading the sample PCAP.
*   **Output Understanding:** Provide a concrete reference of the UDM format produced by the `json2udm.py` script for a specific type of traffic.

## In-depth Script Conversion Testing

It is important to note that these sample files are intended for a general validation of the pipeline and output format.

For **more detailed and in-depth testing specifically of the `json2udm_cloud.py` conversion script** (including unit tests, handling of various protocols, edge cases, and script performance), please refer to the original project from which this script evolved:

➡️ **[Wireshark-to-Chronicle-Pipeline (Cybersecurity Projects 2024)](https://github.com/fillol/Wireshark-to-Chronicle-Pipeline)**

That repository focused more extensively on the analysis and robustness of the transformation logic from TShark's JSON output to UDM.

---
