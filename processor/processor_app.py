# processor/processor_app.py - Applicazione Flask per Cloud Run (Sfrutta il mio progetto cybersecurity)

import base64
import json
import os
import subprocess
import tempfile
import logging
from flask import Flask, request, Response, jsonify

from google.cloud import storage
# from google.cloud import logging as cloud_logging # Non sembra essere usato attivamente

# --- Configuration ---
INCOMING_BUCKET_NAME = os.environ.get("INCOMING_BUCKET")
OUTPUT_BUCKET_NAME = os.environ.get("OUTPUT_BUCKET")
GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID") # Anche se non usato direttamente qui, è buona pratica averlo

if not INCOMING_BUCKET_NAME:
    logging.critical("CRITICAL ERROR: INCOMING_BUCKET environment variable not set.")
    # In un'app reale, potresti voler terminare o impedire l'avvio di Flask
if not OUTPUT_BUCKET_NAME:
    logging.critical("CRITICAL ERROR: OUTPUT_BUCKET environment variable not set.")

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

app = Flask(__name__)

# --- Google Cloud Storage Client Initialization ---
# Variabile globale per l'istanza del client
storage_client_instance = None
try:
    storage_client_instance = storage.Client()
    logging.info("Google Cloud Storage client object created successfully.")
except Exception as e:
    logging.critical(f"CRITICAL ERROR: Failed to create Google Cloud Storage client object: {e}", exc_info=True)
    # Se il client non può essere creato, l'app non funzionerà con GCS.
    # get_storage_client() gestirà questo caso restituendo None.

# Flags per tracciare la verifica dei bucket (semplice caching per istanza worker)
_incoming_bucket_verified = False
_output_bucket_verified = False

def get_verified_storage_client():
    """
    Restituisce l'istanza del client di storage se i bucket necessari sono verificati.
    Tenta di verificare i bucket se non ancora fatto e il client esiste.
    Restituisce None se il client non è stato creato o i bucket non sono accessibili/verificati.
    """
    global _incoming_bucket_verified, _output_bucket_verified

    if not storage_client_instance:
        logging.error("Storage client object was not created at application startup.")
        return None

    client_to_use = storage_client_instance

    # Verifica il bucket di input se non già fatto
    if not _incoming_bucket_verified:
        if not INCOMING_BUCKET_NAME: # Controllo di sicurezza
            logging.error("INCOMING_BUCKET_NAME is not set, cannot verify.")
            return None
        try:
            bucket = client_to_use.lookup_bucket(INCOMING_BUCKET_NAME)
            if bucket:
                logging.info(f"Incoming bucket '{INCOMING_BUCKET_NAME}' successfully verified.")
                _incoming_bucket_verified = True
            else:
                logging.error(f"Verification failed: Incoming bucket '{INCOMING_BUCKET_NAME}' not found or no access.")
                return None # Fallisce se il bucket non è accessibile
        except Exception as e:
            logging.error(f"Exception during incoming bucket ('{INCOMING_BUCKET_NAME}') verification: {e}", exc_info=True)
            return None

    # Verifica il bucket di output se non già fatto
    if not _output_bucket_verified:
        if not OUTPUT_BUCKET_NAME: # Controllo di sicurezza
            logging.error("OUTPUT_BUCKET_NAME is not set, cannot verify.")
            return None
        try:
            bucket = client_to_use.lookup_bucket(OUTPUT_BUCKET_NAME)
            if bucket:
                logging.info(f"Output bucket '{OUTPUT_BUCKET_NAME}' successfully verified.")
                _output_bucket_verified = True
            else:
                logging.error(f"Verification failed: Output bucket '{OUTPUT_BUCKET_NAME}' not found or no access.")
                return None
        except Exception as e:
            logging.error(f"Exception during output bucket ('{OUTPUT_BUCKET_NAME}') verification: {e}", exc_info=True)
            return None
            
    if _incoming_bucket_verified and _output_bucket_verified:
        return client_to_use
    else:
        # Questo non dovrebbe accadere se la logica sopra è corretta e i bucket esistono/sono accessibili
        logging.error("Bucket verification flags indicate failure, but no specific error was caught. Returning no client.")
        return None

# --- Health Check Route ---
@app.route('/', methods=['GET'])
def health_check():
    """Health check endpoint."""
    # Potresti opzionalmente verificare la disponibilità del client GCS qui per un health check più completo
    # client = get_verified_storage_client()
    # if client:
    #     return jsonify(status="ok", storage_ready=True), 200
    # else:
    #     # Se il client non è pronto, potresti voler restituire uno stato degradato
    #     # ma per la startup probe di Cloud Run, un semplice 200 OK è spesso sufficiente
    #     # per indicare che l'app Flask è partita.
    #     return jsonify(status="ok", storage_ready=False), 200 # o 503 se vuoi che la probe fallisca
    return jsonify(status="ok"), 200

# --- Route for Pub/Sub Push ---
@app.route('/', methods=['POST'])
def process_pcap_notification():
    # Ottieni il client di storage (e verifica i bucket se è la prima volta per questa istanza)
    # Questa chiamata ora gestisce il logging degli errori di verifica internamente.
    active_storage_client = get_verified_storage_client()

    if not active_storage_client:
        # get_verified_storage_client() logga già l'errore specifico.
        # Pub/Sub ritenterà questo messaggio in caso di 500.
        return "Internal Server Error: Storage client not available or buckets not accessible.", 500

    envelope = request.get_json(silent=True)
    if not envelope:
        logging.error("Bad Request: No JSON payload received.")
        return "Bad Request: No JSON payload", 400

    if not isinstance(envelope, dict) or "message" not in envelope:
        logging.error(f"Bad Request: Invalid Pub/Sub message format: {envelope}")
        return "Bad Request: Invalid Pub/Sub message format", 400

    pubsub_message = envelope["message"]
    pcap_filename = ""

    if isinstance(pubsub_message, dict) and "data" in pubsub_message:
        try:
            pcap_filename = base64.b64decode(pubsub_message["data"]).decode("utf-8").strip()
            logging.info(f"Received notification for pcap file: {pcap_filename}")
        except Exception as e:
            logging.error(f"Error decoding Pub/Sub message data: {e}", exc_info=True)
            return "Bad Request: Could not decode message data", 400
    else:
         logging.error(f"Bad Request: Invalid Pub/Sub message structure: {pubsub_message}")
         return "Bad Request: Invalid Pub/Sub message structure", 400

    if not pcap_filename or '/' in pcap_filename: # Basic check for invalid/path traversal
        logging.error(f"Bad Request: Invalid pcap filename received: '{pcap_filename}'")
        return "Bad Request: Invalid pcap filename", 400

    # --- Processing Steps ---
    with tempfile.TemporaryDirectory() as temp_dir:
        local_pcap_path = os.path.join(temp_dir, pcap_filename)
        local_json_path = os.path.join(temp_dir, pcap_filename + ".json") # tshark output
        base_output_name = os.path.splitext(pcap_filename)[0]
        udm_output_filename = f"{base_output_name}.udm.json" # json2udm output
        local_udm_path = os.path.join(temp_dir, udm_output_filename)

        try:
            # 1. Download pcap from GCS
            logging.info(f"Downloading gs://{INCOMING_BUCKET_NAME}/{pcap_filename} to {local_pcap_path}")
            blob = active_storage_client.bucket(INCOMING_BUCKET_NAME).blob(pcap_filename)
            blob.download_to_filename(local_pcap_path)
            logging.info("Download complete.")

            # 2. Convert pcap to JSON using tshark
            logging.info(f"Converting {local_pcap_path} to JSON...")
            tshark_command = ["tshark", "-r", local_pcap_path, "-T", "json"]
            with open(local_json_path, "w") as json_file:
                process = subprocess.run(tshark_command, stdout=json_file, stderr=subprocess.PIPE, text=True, check=True)
            logging.info(f"tshark conversion successful. Output at {local_json_path}")
            if process.stderr: logging.warning(f"tshark stderr: {process.stderr}")

            # 3. Convert JSON to UDM using the Python script
            logging.info(f"Converting {local_json_path} to UDM ({local_udm_path})...")
            udm_script_command = ["python3", "/app/json2udm_cloud.py", local_json_path, local_udm_path]
            process = subprocess.run(udm_script_command, capture_output=True, text=True, check=True)
            logging.info(f"UDM conversion successful.")
            if process.stdout: logging.info(f"json2udm_cloud.py stdout: {process.stdout.strip()}")
            if process.stderr: logging.warning(f"json2udm_cloud.py stderr: {process.stderr.strip()}")
            
            # Controlla se il file UDM è stato creato e non è vuoto
            if not os.path.exists(local_udm_path) or os.path.getsize(local_udm_path) == 0:
                logging.error(f"UDM file {local_udm_path} was not created or is empty after conversion. Check json2udm_cloud.py logs.")
                # Potrebbe essere un 500 perché il processamento è fallito, PubSub ritenterà
                return "Internal Server Error: UDM file generation failed", 500

            # 4. Upload UDM JSON to GCS Output Bucket
            logging.info(f"Uploading {local_udm_path} to gs://{OUTPUT_BUCKET_NAME}/{udm_output_filename}")
            output_blob = active_storage_client.bucket(OUTPUT_BUCKET_NAME).blob(udm_output_filename)
            output_blob.upload_from_filename(local_udm_path)
            logging.info("Upload complete.")

            logging.info(f"Successfully processed {pcap_filename}")
            return Response(status=204) # 204 No Content

        except storage.exceptions.NotFound:
             logging.error(f"Error: pcap file gs://{INCOMING_BUCKET_NAME}/{pcap_filename} not found.", exc_info=True)
             # Acknowledge message (2xx) so Pub/Sub doesn't retry for a non-existent file.
             return Response(status=204)
        except subprocess.CalledProcessError as e:
            logging.error(f"Error during subprocess execution: {e.cmd}", exc_info=True)
            # logging.error(f"Command: {' '.join(e.cmd)}") # Già in exc_info con Python 3.7+
            logging.error(f"Return Code: {e.returncode}")
            if e.stdout: logging.error(f"Stdout: {e.stdout.strip()}")
            if e.stderr: logging.error(f"Stderr: {e.stderr.strip()}")
            return "Internal Server Error during processing", 500 # Pub/Sub might retry
        except Exception as e:
            logging.error(f"An unexpected error occurred processing {pcap_filename}: {e}", exc_info=True)
            return "Internal Server Error", 500 # Pub/Sub might retry

# --- Main Execution (for local development, Gunicorn handles this in Cloud Run) ---
if __name__ == '__main__':
    # Imposta le variabili d'ambiente necessarie per il test locale
    # os.environ["INCOMING_BUCKET"] = "tuo-bucket-input-locale"
    # os.environ["OUTPUT_BUCKET"] = "tuo-bucket-output-locale"
    # os.environ["GCP_PROJECT_ID"] = "tuo-progetto-locale" # Se necessario per il client

    if not INCOMING_BUCKET_NAME or not OUTPUT_BUCKET_NAME:
        print("Per l'esecuzione locale, imposta le variabili d'ambiente INCOMING_BUCKET e OUTPUT_BUCKET.")
    else:
        app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 8080)), debug=True) # debug=True per lo sviluppo