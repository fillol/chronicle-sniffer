#!/bin/bash
# sniffer/sniffer_entrypoint.sh - Captures network traffic, uploads to GCS, and notifies Pub/Sub.
# This script runs inside a Docker container, typically on premises.

echo "--- Sniffer Container Starting ---"

# --- Configuration (from Environment Variables) ---
GCP_PROJECT_ID="${GCP_PROJECT_ID}"                # GCP Project ID
INCOMING_BUCKET="${INCOMING_BUCKET}"            # GCS bucket for raw .pcap uploads
PUBSUB_TOPIC_ID="${PUBSUB_TOPIC_ID}"            # Pub/Sub topic for notifications
GCP_KEY_FILE="${GCP_KEY_FILE:-/app/gcp-key/key.json}" # Path to Service Account key within the container

# tshark options - configurable via environment variables
INTERFACE=""                                      # Network interface for capture (auto-detected if empty)
ROTATE="${ROTATE:-"-b filesize:10240 -b duration:60"}" # tshark rotation params (e.g., 10MB or 60s)
LIMITS="${LIMITS:-}"                              # Other tshark limits (e.g., -c packet_count)
CAPTURE_DIR="/app/captures"                       # Local directory for storing .pcap files
FILENAME_BASE="capture"                           # Base for .pcap filenames (e.g., capture_00001_timestamp.pcap)

# --- Validate Configuration & Setup ---
# Ensure critical environment variables are set.
if [ -z "$GCP_PROJECT_ID" ] || [ -z "$INCOMING_BUCKET" ] || [ -z "$PUBSUB_TOPIC_ID" ]; then
    echo "Error: GCP_PROJECT_ID, INCOMING_BUCKET, and PUBSUB_TOPIC_ID must be set."
    exit 1
fi
# Check for Service Account key file.
if [ ! -f "$GCP_KEY_FILE" ]; then
    echo "Error: Service Account key file not found at $GCP_KEY_FILE."
    echo "Ensure the key is correctly mounted to this path in the container."
    exit 1
fi
# Verify required tools are installed.
if ! command -v tshark &> /dev/null; then echo "Error: tshark not found."; exit 1; fi
if ! command -v gcloud &> /dev/null; then echo "Error: gcloud not found."; exit 1; fi

# Activate Service Account using the provided key file for gcloud operations.
echo "Activating Service Account using key $GCP_KEY_FILE..."
gcloud auth activate-service-account --key-file="$GCP_KEY_FILE" --project="$GCP_PROJECT_ID"
if [ $? -ne 0 ]; then echo "Error: Failed to activate service account."; exit 1; fi
echo "Service Account activated."
gcloud auth list # Display active gcloud account for verification.

# Auto-detect active network interface if not explicitly set.
# This loop tries to find a suitable non-loopback, non-docker, etc., interface that is 'up'.
echo "Searching for active network interface..."
while true; do
    for iface_path in /sys/class/net/*; do
        iface=$(basename "$iface_path")
        # Skip common virtual or loopback interfaces.
        case "$iface" in lo|docker*|br-*|tun*|veth*|wg*) continue ;; esac
        # Check if the interface operational state is "up".
        if [[ -f "$iface_path/operstate" && $(< "$iface_path/operstate") == "up" ]]; then
            INTERFACE="-i $iface" # Set tshark interface option.
            echo "Active network interface found: $iface"
            break 2 # Break out of both loops.
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

# Start tshark in the background to capture packets.
# It will rotate files based on $ROTATE parameters.
tshark $INTERFACE $ROTATE $LIMITS -w "$CAPTURE_DIR/$FILENAME_BASE.pcap" &
TSHARK_PID=$! # Store tshark's Process ID.
echo "tshark started with PID $TSHARK_PID"
sleep 5 # Give tshark a moment to start and create its first file.

processed_files=() # Array to keep track of files already uploaded/notified.

# Helper function to check if a file is already in the processed_files array.
is_processed() {
  local file_to_check=$1; shift; local list=("$@")
  for item in "${list[@]}"; do [[ "$item" == "$file_to_check" ]] && return 0; done # 0 for true (found)
  return 1 # 1 for false (not found)
}

# Main loop: monitors tshark and processes completed capture files.
# Loop continues as long as the tshark process is running.
while kill -0 $TSHARK_PID 2>/dev/null; do
    # Attempt to identify the file tshark is currently writing to.
    # This helps avoid processing the active capture file prematurely.
    active_file_path=$(lsof -p $TSHARK_PID -Fn 2>/dev/null | grep '^n' | cut -c2- | grep "$CAPTURE_DIR/.*\.pcap$" | head -n 1)
    active_file=$(basename "$active_file_path" 2>/dev/null) # Extract just the filename.

    # Find all .pcap files in the capture directory matching the base name.
    find "$CAPTURE_DIR" -maxdepth 1 -name "${FILENAME_BASE}_*.pcap" -type f | while read -r pcap_file; do
        base_pcap_file=$(basename "$pcap_file")

        # Skip if this is the file tshark is currently writing to.
        if [[ -n "$active_file" && "$base_pcap_file" == "$active_file" ]]; then continue; fi
        # Skip if this file has already been processed.
        if is_processed "$base_pcap_file" "${processed_files[@]}"; then continue; fi

        echo "[$(date)] Detected completed file: $base_pcap_file"

        # 1. Upload the completed .pcap file to Google Cloud Storage.
        echo "[$(date)] Uploading $base_pcap_file to gs://${INCOMING_BUCKET}/..."
        if gcloud storage cp "$pcap_file" "gs://${INCOMING_BUCKET}/" --project "$GCP_PROJECT_ID"; then
            echo "[$(date)] Upload successful."

            # 2. Publish a notification to Pub/Sub with the filename.
            echo "[$(date)] Publishing notification for $base_pcap_file to ${PUBSUB_TOPIC_ID}..."
            if gcloud pubsub topics publish "$PUBSUB_TOPIC_ID" --message "$base_pcap_file" --project "$GCP_PROJECT_ID"; then
                echo "[$(date)] Notification published successfully."
                processed_files+=("$base_pcap_file") # Add to processed list.
                # 3. Remove the local .pcap file after successful upload and notification.
                rm "$pcap_file"
                echo "[$(date)] Removed local file: $pcap_file"
            else
                echo "[$(date)] Error: Failed to publish notification for $base_pcap_file."
                # File is not removed or added to processed_files, will retry on next loop iteration.
            fi
        else
            echo "[$(date)] Error: Failed to upload $base_pcap_file to GCS."
            # Upload failed; will retry on next loop iteration.
        fi
    done
    sleep 10 # Wait before checking for new completed files again.
done

echo "tshark process ended. Exiting sniffer."
# Ensure tshark is terminated if the script exits for any reason.
trap 'echo "Terminating tshark due to script exit"; kill $TSHARK_PID 2>/dev/null' EXIT
wait $TSHARK_PID # Wait for tshark to fully exit.

echo "--- Sniffer Container Finished ---"