#!/bin/bash
# sniffer/sniffer_entrypoint.sh - Captures network traffic, uploads to GCS, and notifies Pub/Sub.
# This script runs inside a Docker container, typically on premises or an edge device.

# --- Configuration (from Environment Variables) ---
GCP_PROJECT_ID="${GCP_PROJECT_ID}"                # GCP Project ID
INCOMING_BUCKET="${INCOMING_BUCKET}"            # GCS bucket for raw .pcap uploads
PUBSUB_TOPIC_ID="${PUBSUB_TOPIC_ID}"            # Pub/Sub topic for notifications
GCP_KEY_FILE="${GCP_KEY_FILE:-/app/gcp-key/key.json}" # Path to Service Account key within the container
SNIFFER_ID="${SNIFFER_ID:-unknown-sniffer}"     # Unique ID for this sniffer instance

# tshark options - configurable via environment variables
INTERFACE=""                                      # Network interface for capture (auto-detected if empty)
INTERFACE_NAME_ONLY="unknown-interface"           # To store just the name of the interface
ROTATE="${ROTATE:-"-b filesize:10240 -b duration:60"}" # tshark rotation params (e.g., 10MB or 60s)
LIMITS="${LIMITS:-}"                              # Other tshark limits (e.g., -c packet_count)
CAPTURE_DIR="/app/captures"                       # Local directory for storing .pcap files
FILENAME_BASE="capture"                           # Base for .pcap filenames (e.g., capture_00001_timestamp.pcap)

# --- Validate Configuration & Setup ---
echo "--- Sniffer Container Starting (ID: $SNIFFER_ID) ---"
# Ensure critical environment variables are set.
if [ -z "$GCP_PROJECT_ID" ] || [ -z "$INCOMING_BUCKET" ] || [ -z "$PUBSUB_TOPIC_ID" ] || [ "$SNIFFER_ID" == "unknown-sniffer" ]; then
    echo "Error (ID: $SNIFFER_ID): GCP_PROJECT_ID, INCOMING_BUCKET, PUBSUB_TOPIC_ID, and SNIFFER_ID must be set."
    exit 1
fi
# Check for Service Account key file.
if [ ! -f "$GCP_KEY_FILE" ]; then
    echo "Error (ID: $SNIFFER_ID): Service Account key file not found at $GCP_KEY_FILE."
    echo "(ID: $SNIFFER_ID) Ensure the key is correctly mounted to this path in the container."
    exit 1
fi
# Verify required tools are installed.
if ! command -v tshark &> /dev/null; then echo "Error: tshark not found."; exit 1; fi
if ! command -v gcloud &> /dev/null; then echo "Error: gcloud not found."; exit 1; fi
if ! command -v stat &> /dev/null; then echo "Error: stat not found."; exit 1; fi
if ! command -v lsof &> /dev/null; then echo "Error: lsof not found (required from procps package)."; exit 1; fi


# Activate Service Account using the provided key file for gcloud operations.
echo "(ID: $SNIFFER_ID) Activating Service Account using key $GCP_KEY_FILE..."
gcloud auth activate-service-account --key-file="$GCP_KEY_FILE" --project="$GCP_PROJECT_ID"
if [ $? -ne 0 ]; then echo "Error (ID: $SNIFFER_ID): Failed to activate service account."; exit 1; fi
echo "(ID: $SNIFFER_ID) Service Account activated."
gcloud auth list # Display active gcloud account for verification.

# Auto-detect active network interface if not explicitly set.
# This loop tries to find a suitable non-loopback, non-docker, etc., interface that is 'up'.
if [ -z "$INTERFACE" ]; then # Only auto-detect if INTERFACE is not already set by env var
    echo "(ID: $SNIFFER_ID) Network interface not specified. Searching for active network interface..."
    detected_iface_found=false
    while true; do # Loop for retrying detection
        for iface_path in /sys/class/net/*; do
            iface_name=$(basename "$iface_path")
            # Skip common virtual or loopback interfaces. Add others if needed.
            case "$iface_name" in lo|docker*|br-*|tun*|veth*|wg*|virbr*|kube-ipvs*) continue ;; esac
            # Check if the interface operational state is "up".
            if [[ -f "$iface_path/operstate" && $(< "$iface_path/operstate") == "up" ]]; then
                # Further check: Ensure it has an IP address (more robust check for "active")
                # This requires 'ip' command from 'iproute2' package
                if command -v ip >/dev/null && ip addr show dev "$iface_name" | grep -qw inet; then
                    INTERFACE_NAME_ONLY=$iface_name
                    INTERFACE="-i $iface_name" # Set tshark interface option.
                    echo "(ID: $SNIFFER_ID) Active network interface found and selected: $INTERFACE_NAME_ONLY"
                    detected_iface_found=true
                    break 2 # Break out of both loops (inner for, outer while).
                fi
            fi
        done
        if [ "$detected_iface_found" = false ]; then
            echo "(ID: $SNIFFER_ID) No suitable active interface found with an IP address. Retrying in 10 seconds..."
            sleep 10
        fi
    done
else
    # If INTERFACE was set via environment variable, use it directly.
    # Assume it's just the name, so prefix with '-i'.
    INTERFACE_NAME_ONLY=$INTERFACE 
    INTERFACE="-i $INTERFACE"
    echo "(ID: $SNIFFER_ID) Using specified network interface: $INTERFACE_NAME_ONLY"
fi


# --- Capture and Process Loop ---
echo "(ID: $SNIFFER_ID) Starting tshark capture..."
echo "(ID: $SNIFFER_ID)   Interface: $INTERFACE_NAME_ONLY ($INTERFACE)"
echo "(ID: $SNIFFER_ID)   Rotation: $ROTATE"
echo "(ID: $SNIFFER_ID)   Output Dir: $CAPTURE_DIR"
echo "(ID: $SNIFFER_ID)   GCS Bucket: gs://${INCOMING_BUCKET}"
echo "(ID: $SNIFFER_ID)   Pub/Sub Topic: ${PUBSUB_TOPIC_ID}"

# Function for sniffer heartbeat, runs in background
send_heartbeat() {
    while true; do
        # Log current tshark status along with heartbeat
        local tshark_status="stopped"
        if kill -0 $TSHARK_PID 2>/dev/null; then # Check if tshark process exists
            tshark_status="running"
        fi
        echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) (IFACE: $INTERFACE_NAME_ONLY) Heartbeat. tshark PID: $TSHARK_PID (Status: $tshark_status)"
        echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) TSHARK_STATUS: $tshark_status" # Explicit log for TSHARK_STATUS metric
        sleep 60 # Send heartbeat every 60 seconds
    done
}

# Start tshark in the background to capture packets.
# It will rotate files based on $ROTATE parameters.
tshark $INTERFACE $ROTATE $LIMITS -w "$CAPTURE_DIR/$FILENAME_BASE.pcap" &
TSHARK_PID=$! # Store tshark's Process ID.
echo "(ID: $SNIFFER_ID) tshark started with PID $TSHARK_PID"
sleep 5 # Give tshark a moment to start and potentially create its first file.

# Start heartbeat in background
send_heartbeat &
HEARTBEAT_PID=$!

processed_files=() # Array to keep track of files already uploaded/notified.

# Helper function to check if a file is already in the processed_files array.
is_processed() {
  local file_to_check="$1"
  for item in "${processed_files[@]}"; do
    if [[ "$item" == "$file_to_check" ]]; then
      return 0 # 0 for true (found)
    fi
  done
  return 1 # 1 for false (not found)
}

# Graceful shutdown function
graceful_shutdown() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) Received termination signal. Shutting down tshark and heartbeat..."
  # Terminate tshark process
  if kill -0 $TSHARK_PID 2>/dev/null; then
    echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) Sending SIGTERM to tshark (PID: $TSHARK_PID)..."
    kill -TERM $TSHARK_PID
    wait $TSHARK_PID # Wait for tshark to finish
    echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) tshark terminated."
  else
    echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) tshark (PID: $TSHARK_PID) already stopped."
  fi
  # Terminate heartbeat process
  if kill -0 $HEARTBEAT_PID 2>/dev/null; then
    echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) Sending SIGTERM to heartbeat (PID: $HEARTBEAT_PID)..."
    kill -TERM $HEARTBEAT_PID
  fi
  echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) Sniffer shutdown complete."
  exit 0
}

# Trap SIGINT (Ctrl+C) and SIGTERM (docker stop) to call graceful_shutdown
trap graceful_shutdown SIGINT SIGTERM

# Main loop: monitors tshark and processes completed capture files.
# Loop continues as long as the tshark process is running.
while kill -0 $TSHARK_PID 2>/dev/null; do
    # Attempt to identify the file tshark is currently writing to.
    # This helps avoid processing the active capture file prematurely.
    # Filter by process ID and ensure the file is within our CAPTURE_DIR and ends with .pcap or .pcapng
    active_file_path=$(lsof -p $TSHARK_PID -Fn 2>/dev/null | grep '^n' | cut -c2- | grep "^${CAPTURE_DIR}/.*\.pcap*" | head -n 1)
    active_file=$(basename "$active_file_path" 2>/dev/null) # Extract just the filename.

    # Find all .pcap or .pcapng files in the capture directory matching the base name.
    # The ".pcap*" wildcard covers both .pcap and .pcapng extensions.
    find "$CAPTURE_DIR" -maxdepth 1 -name "${FILENAME_BASE}_*.pcap*" -type f | while read -r pcap_file_path; do
        current_pcap_file_basename=$(basename "$pcap_file_path")

        # Skip if this is the file tshark is currently writing to.
        if [[ -n "$active_file" && "$current_pcap_file_basename" == "$active_file" ]]; then
            # echo "[DEBUG] Skipping active file: $current_pcap_file_basename" # Optional debug
            continue
        fi
        # Skip if this file has already been processed.
        if is_processed "$current_pcap_file_basename" "${processed_files[@]}"; then
            # echo "[DEBUG] Skipping already processed file: $current_pcap_file_basename" # Optional debug
            continue
        fi

        echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) Detected completed file: $current_pcap_file_basename"
        
        # Get file size
        file_size_bytes=$(stat -c%s "$pcap_file_path")
        echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) PCAP_SIZE_BYTES: $file_size_bytes FILE: $current_pcap_file_basename"

        # 1. Upload the completed .pcap file to Google Cloud Storage.
        echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) Uploading $current_pcap_file_basename to gs://${INCOMING_BUCKET}/..."
        if gcloud storage cp "$pcap_file_path" "gs://${INCOMING_BUCKET}/" --project "$GCP_PROJECT_ID"; then
            echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) Upload successful for $current_pcap_file_basename."

            # 2. Publish a notification to Pub/Sub with the filename.
            echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) Publishing notification for $current_pcap_file_basename to ${PUBSUB_TOPIC_ID}..."
            if gcloud pubsub topics publish "$PUBSUB_TOPIC_ID" --message "$current_pcap_file_basename" --project "$GCP_PROJECT_ID"; then
                echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) Notification published successfully for $current_pcap_file_basename."
                processed_files+=("$current_pcap_file_basename") # Add to processed list.
                # 3. Remove the local .pcap file after successful upload and notification.
                rm "$pcap_file_path"
                echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) Removed local file: $pcap_file_path"
            else
                echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) Error: Failed to publish notification for $current_pcap_file_basename. Will retry." # Log for Pub/Sub publish error metric
                # File is not removed or added to processed_files, will retry on next loop iteration.
            fi
        else
            echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) Error: Failed to upload $current_pcap_file_basename to GCS. Will retry."
            # Upload failed; will retry on next loop iteration.
        fi
    done
    sleep 10 # Wait before checking for new completed files again.
done

echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] (ID: $SNIFFER_ID) tshark process (PID: $TSHARK_PID) appears to have ended. Initiating shutdown..."
graceful_shutdown # Call graceful shutdown if tshark loop exits

echo "[$(date +'%Y-%m-%dT%H:%M:%SZ')] --- Sniffer Container (ID: $SNIFFER_ID) Finished ---"