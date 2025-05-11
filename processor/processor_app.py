# processor/processor_app.py - Applicazione Flask per Cloud Run (Sfrutta il mio progetto cybersecurity)

import base64
import json
import os
import subprocess
import tempfile
import logging
from flask import Flask, request, Response, jsonify

from google.cloud import storage
from google.cloud import logging as cloud_logging

# --- Configuration ---
INCOMING_BUCKET_NAME = os.environ.get("INCOMING_BUCKET")
OUTPUT_BUCKET_NAME = os.environ.get("OUTPUT_BUCKET")
GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID")

if not INCOMING_BUCKET_NAME or not OUTPUT_BUCKET_NAME:
    logging.error("Error: INCOMING_BUCKET and OUTPUT_BUCKET env vars must be set.")

# --- Setup Logging ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# --- Flask App ---
app = Flask(__name__)

# --- Initialize Google Cloud Storage Client ---
try:
    storage_client = storage.Client()
    # Verifica esistenza bucket all'avvio (opzionale ma utile)
    incoming_bucket = storage_client.lookup_bucket(INCOMING_BUCKET_NAME)
    output_bucket = storage_client.lookup_bucket(OUTPUT_BUCKET_NAME)
    if not incoming_bucket:
         logging.error(f"Error: Incoming bucket '{INCOMING_BUCKET_NAME}' not found or no access.")
         storage_client = None # Impedisce operazioni successive
    if not output_bucket:
         logging.error(f"Error: Output bucket '{OUTPUT_BUCKET_NAME}' not found or no access.")
         storage_client = None
    if storage_client:
        logging.info(f"Storage client initialized. Incoming: {INCOMING_BUCKET_NAME}, Output: {OUTPUT_BUCKET_NAME}")
except Exception as e:
    logging.error(f"Failed to initialize Storage client: {e}")
    storage_client = None

# --- Health Check Route ---
@app.route('/', methods=['GET'])
def health_check():
    """Health check endpoint."""
    return jsonify(status="ok"), 200

# --- Route for Pub/Sub Push ---
@app.route('/', methods=['POST'])
def process_pcap_notification():
    """
    Receives Pub/Sub push notifications, processes the referenced pcap file.
    Returns appropriate HTTP status codes for Pub/Sub acknowledgement.
    """
    if not storage_client:
        logging.error("Storage client not available.")
        # 500 Internal Server Error - Pub/Sub will retry
        return "Internal Server Error: Storage client not initialized", 500

    envelope = request.get_json(silent=True) # silent=True per non lanciare eccezione se non è JSON
    if not envelope:
        logging.error("Bad Request: No JSON payload received.")
        # 400 Bad Request - Pub/Sub should not retry
        return "Bad Request: No JSON payload", 400

    if not isinstance(envelope, dict) or "message" not in envelope:
        logging.error(f"Bad Request: Invalid Pub/Sub message format: {envelope}")
        # 400 Bad Request
        return "Bad Request: Invalid Pub/Sub message format", 400

    pubsub_message = envelope["message"]
    pcap_filename = ""

    if isinstance(pubsub_message, dict) and "data" in pubsub_message:
        try:
            pcap_filename = base64.b64decode(pubsub_message["data"]).decode("utf-8").strip()
            logging.info(f"Received notification for pcap file: {pcap_filename}")
        except Exception as e:
            logging.error(f"Error decoding Pub/Sub message data: {e}")
            # 400 Bad Request
            return "Bad Request: Could not decode message data", 400
    else:
         logging.error(f"Bad Request: Invalid Pub/Sub message structure: {pubsub_message}")
         # 400 Bad Request
         return "Bad Request: Invalid Pub/Sub message structure", 400

    if not pcap_filename or '/' in pcap_filename: # Basic check for invalid/path traversal
        logging.error(f"Bad Request: Invalid pcap filename received: '{pcap_filename}'")
         # 400 Bad Request
        return "Bad Request: Invalid pcap filename", 400

    # --- Processing Steps ---
    with tempfile.TemporaryDirectory() as temp_dir:
        local_pcap_path = os.path.join(temp_dir, pcap_filename)
        local_json_path = os.path.join(temp_dir, pcap_filename + ".json")
        base_output_name = os.path.splitext(pcap_filename)[0]
        udm_output_filename = f"{base_output_name}.udm.json"
        local_udm_path = os.path.join(temp_dir, udm_output_filename)

        try:
            # 1. Download pcap from GCS
            logging.info(f"Downloading gs://{INCOMING_BUCKET_NAME}/{pcap_filename} to {local_pcap_path}")
            blob = storage_client.bucket(INCOMING_BUCKET_NAME).blob(pcap_filename)
            blob.download_to_filename(local_pcap_path)
            logging.info("Download complete.")

            # 2. Convert pcap to JSON using tshark
            logging.info(f"Converting {local_pcap_path} to JSON...")
            tshark_command = ["tshark", "-r", local_pcap_path, "-T", "json"]
            with open(local_json_path, "w") as json_file:
                # check=True lancia CalledProcessError se tshark fallisce
                process = subprocess.run(tshark_command, stdout=json_file, stderr=subprocess.PIPE, text=True, check=True)
            logging.info(f"tshark conversion successful.")
            if process.stderr: logging.warning(f"tshark stderr: {process.stderr}")


            # 3. Convert JSON to UDM using the Python script
            logging.info(f"Converting {local_json_path} to UDM...")
            udm_script_command = ["python3", "/app/json2udm_cloud.py", local_json_path, local_udm_path]
            # check=True lancia CalledProcessError se lo script fallisce (exit code non 0)
            process = subprocess.run(udm_script_command, capture_output=True, text=True, check=True)
            logging.info(f"UDM conversion successful.")
            if process.stdout: logging.info(f"json2udm_cloud.py stdout: {process.stdout}")
            if process.stderr: logging.warning(f"json2udm_cloud.py stderr: {process.stderr}")


            # 4. Upload UDM JSON to GCS Output Bucket
            logging.info(f"Uploading {local_udm_path} to gs://{OUTPUT_BUCKET_NAME}/{udm_output_filename}")
            output_blob = storage_client.bucket(OUTPUT_BUCKET_NAME).blob(udm_output_filename)
            output_blob.upload_from_filename(local_udm_path)
            logging.info("Upload complete.")

            # --- Success ---
            logging.info(f"Successfully processed {pcap_filename}")
            # 2xx status code acknowledges the Pub/Sub message
            # Using 204 No Content as we don't need to return a body
            return Response(status=204)

        except storage.exceptions.NotFound:
             logging.error(f"Error: pcap file gs://{INCOMING_BUCKET_NAME}/{pcap_filename} not found.")
             # 404 Not Found - Acknowledge message (return 2xx or 4xx) so Pub/Sub doesn't retry for a missing file.
             # Returning 204 here to ack the message, as retrying won't help.
             return Response(status=204)
        except subprocess.CalledProcessError as e:
            logging.error(f"Error during subprocess execution: {e}")
            logging.error(f"Command: {' '.join(e.cmd)}")
            logging.error(f"Return Code: {e.returncode}")
            logging.error(f"Stdout: {e.stdout}")
            logging.error(f"Stderr: {e.stderr}")
            # 500 Internal Server Error - Pub/Sub might retry
            return "Internal Server Error during processing", 500
        except Exception as e:
            logging.error(f"An unexpected error occurred processing {pcap_filename}: {e}", exc_info=True)
            # 500 Internal Server Error
            return "Internal Server Error", 500

# --- Main Execution ---
if __name__ == '__main__':
    # Development server (non usare in produzione con Gunicorn)
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 8080)), debug=False)
