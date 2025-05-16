#!/bin/bash
# sniffer/sniffer_entrypoint.sh - Cattura, Upload GCS, Notifica Pub/Sub

echo "--- Sniffer Container Starting ---"

# --- Configuration (Environment Variables) ---
GCP_PROJECT_ID="${GCP_PROJECT_ID}"
INCOMING_BUCKET="${INCOMING_BUCKET}" 
PUBSUB_TOPIC_ID="${PUBSUB_TOPIC_ID}" 
GCP_KEY_FILE="${GCP_KEY_FILE:-/app/gcp-key/key.json}" # Percorso chiave SA nel container

# tshark options
INTERFACE="" 
ROTATE="${ROTATE:-"-b filesize:10240 -b duration:60"}" 
LIMITS="${LIMITS:-}" 
CAPTURE_DIR="/app/captures"
FILENAME_BASE="capture"

# --- Validate Configuration & Setup ---
if [ -z "$GCP_PROJECT_ID" ] || [ -z "$INCOMING_BUCKET" ] || [ -z "$PUBSUB_TOPIC_ID" ]; then
    echo "Error: GCP_PROJECT_ID, INCOMING_BUCKET, and PUBSUB_TOPIC_ID must be set."
    exit 1
fi
if [ ! -f "$GCP_KEY_FILE" ]; then
    echo "Error: Service Account key file not found at $GCP_KEY_FILE."
    echo "Ensure the key is correctly mounted to this path in the container."
    exit 1
fi
if ! command -v tshark &> /dev/null; then echo "Error: tshark not found."; exit 1; fi
if ! command -v gcloud &> /dev/null; then echo "Error: gcloud not found."; exit 1; fi

# Activate Service Account
echo "Activating Service Account using key $GCP_KEY_FILE..."
gcloud auth activate-service-account --key-file="$GCP_KEY_FILE" --project="$GCP_PROJECT_ID"
if [ $? -ne 0 ]; then echo "Error: Failed to activate service account."; exit 1; fi
echo "Service Account activated."
gcloud auth list # Mostra l'account attivo (dovrebbe essere sniffer_sa)

# Auto-detect active network interface
# ... (codice auto-detect come prima) ...
echo "Searching for active network interface..."
while true; do
    for iface_path in /sys/class/net/*; do
        iface=$(basename "$iface_path")
        case "$iface" in lo|docker*|br-*|tun*|veth*|wg*) continue ;; esac
        if [[ -f "$iface_path/operstate" && $(< "$iface_path/operstate") == "up" ]]; then
            INTERFACE="-i $iface"
            echo "Active network interface found: $iface"
            break 2
        fi
    done
    echo "No active interface found. Retrying in 5 seconds..."
    sleep 5
done


# --- Capture and Process Loop ---
echo "Starting tshark capture..."
echo "  Interface: $INTERFACE"
echo "  Rotation: $ROTATE"
echo "  Output Dir: $CAPTURE_DIR"
echo "  GCS Bucket: gs://${INCOMING_BUCKET}"
echo "  Pub/Sub Topic: ${PUBSUB_TOPIC_ID}"

tshark $INTERFACE $ROTATE $LIMITS -w "$CAPTURE_DIR/$FILENAME_BASE.pcap" &
TSHARK_PID=$!
echo "tshark started with PID $TSHARK_PID"
sleep 5 

processed_files=()
is_processed() {
  local file_to_check=$1; shift; local list=("$@")
  for item in "${list[@]}"; do [[ "$item" == "$file_to_check" ]] && return 0; done
  return 1
}

while kill -0 $TSHARK_PID 2>/dev/null; do
    active_file_path=$(lsof -p $TSHARK_PID -Fn 2>/dev/null | grep '^n' | cut -c2- | grep "$CAPTURE_DIR/.*\.pcap$" | head -n 1)
    active_file=$(basename "$active_file_path" 2>/dev/null)

    find "$CAPTURE_DIR" -maxdepth 1 -name "${FILENAME_BASE}_*.pcap" -type f | while read -r pcap_file; do
        base_pcap_file=$(basename "$pcap_file")

        if [[ -n "$active_file" && "$base_pcap_file" == "$active_file" ]]; then continue; fi
        if is_processed "$base_pcap_file" "${processed_files[@]}"; then continue; fi

        echo "[$(date)] Detected completed file: $base_pcap_file"

        echo "[$(date)] Uploading $base_pcap_file to gs://${INCOMING_BUCKET}/..."
        if gcloud storage cp "$pcap_file" "gs://${INCOMING_BUCKET}/" --project "$GCP_PROJECT_ID"; then
            echo "[$(date)] Upload successful."

            echo "[$(date)] Publishing notification for $base_pcap_file to ${PUBSUB_TOPIC_ID}..."
            if gcloud pubsub topics publish "$PUBSUB_TOPIC_ID" --message "$base_pcap_file" --project "$GCP_PROJECT_ID"; then
                echo "[$(date)] Notification published successfully."
                processed_files+=("$base_pcap_file")
                rm "$pcap_file"
                echo "[$(date)] Removed local file: $pcap_file"
            else
                echo "[$(date)] Error: Failed to publish notification for $base_pcap_file."
            fi
        else
            echo "[$(date)] Error: Failed to upload $base_pcap_file to GCS."
        fi
    done
    sleep 10 
done

echo "tshark process ended. Exiting sniffer."
trap 'echo "Terminating tshark due to script exit"; kill $TSHARK_PID 2>/dev/null' EXIT
wait $TSHARK_PID

echo "--- Sniffer Container Finished ---"