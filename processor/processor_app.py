# processor/processor_app.py - Cloud Run Flask App for PCAP to UDM processing.
# Listens to Pub/Sub, downloads PCAP from GCS, converts via tshark & json2udm_cloud.py, uploads UDM to GCS.

import base64
import json
import os
import subprocess
import tempfile
import logging
from flask import Flask, request, Response, jsonify
from datetime import datetime, timezone # Added for latency measurement
from google.api_core import exceptions as google_api_exceptions

from google.cloud import storage

# --- Configuration ---
INCOMING_BUCKET_NAME = os.environ.get("INCOMING_BUCKET")
OUTPUT_BUCKET_NAME = os.environ.get("OUTPUT_BUCKET")
GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID") # For GCS client context

if not INCOMING_BUCKET_NAME:
    logging.critical("CRITICAL: INCOMING_BUCKET env var not set.")
if not OUTPUT_BUCKET_NAME:
    logging.critical("CRITICAL: OUTPUT_BUCKET env var not set.")

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

app = Flask(__name__)

# --- Google Cloud Storage Client Initialization ---
storage_client_instance = None # Global GCS client
try:
    storage_client_instance = storage.Client()
    logging.info("GCS client created.")
except Exception as e:
    logging.critical(f"CRITICAL: Failed to create GCS client: {e}", exc_info=True)

_incoming_bucket_verified = False # Worker-instance flags for bucket verification
_output_bucket_verified = False

def get_verified_storage_client():
    """
    Returns GCS client if buckets are verified. Verifies lazily on first call per worker.
    Lazy verification helps if IAM policies (e.g., via Terraform) need time to propagate
    post-deployment, avoiding a separate re-deploy just for permissions.
    Returns None on client creation failure or if buckets aren't accessible.
    """
    global _incoming_bucket_verified, _output_bucket_verified

    if not storage_client_instance:
        logging.error("Storage client object was not created at application startup.")
        return None

    client_to_use = storage_client_instance

    if not _incoming_bucket_verified:
        if not INCOMING_BUCKET_NAME:
            logging.error("INCOMING_BUCKET_NAME not set; cannot verify.")
            return None
        try:
            if client_to_use.lookup_bucket(INCOMING_BUCKET_NAME):
                logging.info(f"Incoming bucket '{INCOMING_BUCKET_NAME}' verified.")
                _incoming_bucket_verified = True
            else:
                logging.error(f"Failed to verify incoming bucket '{INCOMING_BUCKET_NAME}'.")
                return None
        except Exception as e:
            logging.error(f"Exception verifying incoming bucket '{INCOMING_BUCKET_NAME}': {e}", exc_info=True)
            return None

    if not _output_bucket_verified:
        if not OUTPUT_BUCKET_NAME:
            logging.error("OUTPUT_BUCKET_NAME not set; cannot verify.")
            return None
        try:
            if client_to_use.lookup_bucket(OUTPUT_BUCKET_NAME):
                logging.info(f"Output bucket '{OUTPUT_BUCKET_NAME}' verified.")
                _output_bucket_verified = True
            else:
                logging.error(f"Failed to verify output bucket '{OUTPUT_BUCKET_NAME}'.")
                return None
        except Exception as e:
            logging.error(f"Exception verifying output bucket '{OUTPUT_BUCKET_NAME}': {e}", exc_info=True)
            return None
            
    if _incoming_bucket_verified and _output_bucket_verified:
        return client_to_use
    else:
        logging.error("Bucket verification failed. No client provided.")
        return None

# --- Health Check Route ---
@app.route('/', methods=['GET'])
def health_check():
    """Basic health check for Cloud Run liveness probes."""
    return jsonify(status="ok"), 200

# --- Route for Pub/Sub Push ---
@app.route('/', methods=['POST'])
def process_pcap_notification():
    """Handles Pub/Sub notifications for new PCAP files."""
    processing_start_time = datetime.now(timezone.utc) # For latency measurement

    active_storage_client = get_verified_storage_client()
    if not active_storage_client:
        return "Internal Server Error: GCS client/bucket issue.", 500

    envelope = request.get_json(silent=True)
    if not envelope:
        logging.error("Bad Request: No JSON payload.")
        return "Bad Request: No JSON payload", 400 # No retry

    if not isinstance(envelope, dict) or "message" not in envelope:
        logging.error(f"Bad Request: Invalid Pub/Sub format: {envelope}")
        return "Bad Request: Invalid Pub/Sub format", 400

    pubsub_message = envelope["message"]
    pcap_filename = ""

    if isinstance(pubsub_message, dict) and "data" in pubsub_message:
        try:
            pcap_filename = base64.b64decode(pubsub_message["data"]).decode("utf-8").strip()
            logging.info(f"Notification for pcap: {pcap_filename}")
        except Exception as e:
            logging.error(f"Error decoding Pub/Sub data: {e}", exc_info=True)
            return "Bad Request: Cannot decode message data", 400
    else:
         logging.error(f"Bad Request: Invalid Pub/Sub structure: {pubsub_message}")
         return "Bad Request: Invalid Pub/Sub structure", 400

    if not pcap_filename or '/' in pcap_filename: # Basic filename validation
        logging.error(f"Bad Request: Invalid pcap filename: '{pcap_filename}'")
        return "Bad Request: Invalid pcap filename", 400

    # --- Processing Steps ---
    with tempfile.TemporaryDirectory() as temp_dir:
        local_pcap_path = os.path.join(temp_dir, pcap_filename)
        local_json_path = os.path.join(temp_dir, pcap_filename + ".json") # tshark JSON output
        base_output_name = os.path.splitext(pcap_filename)[0]
        udm_output_filename = f"{base_output_name}.udm.json" # Final UDM output name
        local_udm_path = os.path.join(temp_dir, udm_output_filename)

        try:
            # 1. Download pcap from GCS
            logging.info(f"Downloading gs://{INCOMING_BUCKET_NAME}/{pcap_filename} to {local_pcap_path}")
            active_storage_client.bucket(INCOMING_BUCKET_NAME).blob(pcap_filename).download_to_filename(local_pcap_path)
            logging.info(f"Download complete for {pcap_filename}.") # Confirmation for success metric

            # 2. Convert pcap to JSON (tshark)
            logging.info(f"Converting {local_pcap_path} to JSON...")
            tshark_command = ["tshark", "-r", local_pcap_path, "-T", "json"]
            with open(local_json_path, "w") as json_file:
                process = subprocess.run(tshark_command, stdout=json_file, stderr=subprocess.PIPE, text=True, check=True)
            logging.info(f"tshark conversion successful: {local_json_path}")
            if process.stderr: logging.warning(f"tshark stderr: {process.stderr.strip()}")

            # 3. Convert JSON to UDM (json2udm_cloud.py)
            logging.info(f"Converting {local_json_path} to UDM: {local_udm_path}")
            udm_script_command = ["python3", "/app/json2udm_cloud.py", local_json_path, local_udm_path]
            process = subprocess.run(udm_script_command, capture_output=True, text=True, check=True)
            logging.info(f"UDM conversion script done for {pcap_filename}.") # Confirmation
            if process.stdout: logging.info(f"json2udm_cloud.py stdout: {process.stdout.strip()}")
            if process.stderr: logging.warning(f"json2udm_cloud.py stderr: {process.stderr.strip()}")
            
            if not os.path.exists(local_udm_path) or os.path.getsize(local_udm_path) == 0:
                logging.error(f"UDM file {local_udm_path} missing or empty post-conversion for {pcap_filename}.")
                return "Internal Server Error: UDM generation failed.", 500 # Retry

            # 4. Upload UDM JSON to GCS
            logging.info(f"Uploading {local_udm_path} to gs://{OUTPUT_BUCKET_NAME}/{udm_output_filename}")
            active_storage_client.bucket(OUTPUT_BUCKET_NAME).blob(udm_output_filename).upload_from_filename(local_udm_path)
            logging.info(f"Upload complete for {udm_output_filename}.") # Confirmation

            processing_end_time = datetime.now(timezone.utc)
            processing_duration_seconds = (processing_end_time - processing_start_time).total_seconds()
            logging.info(f"PROCESSING_DURATION_SECONDS: {processing_duration_seconds:.3f} FILE: {pcap_filename}")

            logging.info(f"Successfully processed {pcap_filename}")
            return Response(status=204) # OK, No Content for Pub/Sub ACK

        except google_api_exceptions.NotFound:
             logging.error(f"Error: pcap gs://{INCOMING_BUCKET_NAME}/{pcap_filename} not found.", exc_info=False)
             return Response(status=204) # ACK Pub/Sub (don't retry for non-existent file)
        except subprocess.CalledProcessError as e:
            error_message = e.stderr.strip() if e.stderr else e.stdout.strip()
            if "tshark" in ' '.join(e.cmd):
                 logging.error(f"Subprocess error (tshark): CMD: {' '.join(e.cmd)} ERR: {error_message}", exc_info=False)
            else: # Assumed UDM script error
                 logging.error(f"Subprocess error (json2udm): CMD: {' '.join(e.cmd)} ERR: {error_message}", exc_info=False)
            return "Internal Server Error during processing step.", 500 # Retry
        except Exception as e:
            logging.error(f"Unexpected error processing {pcap_filename}: {e}", exc_info=True)
            return "Internal Server Error", 500 # Retry

# --- Main Execution (for local development) ---
if __name__ == '__main__':
    # For local testing, ensure INCOMING_BUCKET and OUTPUT_BUCKET env vars are set.
    if not INCOMING_BUCKET_NAME or not OUTPUT_BUCKET_NAME:
        print("Set INCOMING_BUCKET and OUTPUT_BUCKET environment variables for local run.")
    else:
        # Cloud Run uses PORT env var. debug=True for local dev.
        app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 8080)), debug=True)