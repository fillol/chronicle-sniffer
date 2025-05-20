#!/bin/bash
# This script is executed upon the first boot of the GCE VM.
# It prepares the environment to run the sniffer Docker container by:
# - Installing necessary packages (Docker, Docker Compose, network tools).
# - Pulling the sniffer Docker image specified in VM metadata. This image is expected
#   to be publicly available (e.g., Docker Hub) or in an Artifact Registry repository
#   accessible by the VM's service account.
# - Configuring Docker authentication for Artifact Registry if the image is hosted there.
# - Creating a directory structure and configuration files (.env, a base docker-compose.yml,
#   and a docker-compose.override.yml) for the sniffer container.
# - The base docker-compose.yml on the VM will use the 'image' directive, not 'build'.
# - The docker-compose.override.yml will add VM-specific settings like volumes and network.
# - Setting up a standard host path for the GCP Service Account key, which the user
#   will need to copy to the VM manually.

set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail # The return value of a pipeline is the status of the last command to exit with a non-zero status.

echo "--- VM Startup Script (External File) Started ---"

# Function to retrieve instance metadata values passed by Terraform
get_metadata_value() {
  local key_name="$1"
  # Query the metadata server for the attribute
  local value=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/${key_name}")
  if [ -z "$value" ] && [ "$value" != " " ]; then # Check if metadata is empty or not found
    echo "ERROR: Metadata for '$key_name' not found or is empty!" >&2
    # Consider exiting here if the metadata is critical, or let later checks handle it
  fi
  echo "$value"
}

echo "Retrieving metadata provided by Terraform..."
SNIFFER_IMAGE_URI_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_IMAGE_URI")
VM_GCP_PROJECT_ID_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_GCP_PROJECT_ID")
VM_INCOMING_BUCKET_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_INCOMING_BUCKET")
VM_PUBSUB_TOPIC_ID_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_PUBSUB_TOPIC_ID")
VM_SNIFFER_ID_FROM_METADATA=$(get_metadata_value "VM_SNIFFER_ID")


echo "Retrieved metadata values:" # Not printing sensitive or large values like compose content
echo "  SNIFFER_IMAGE_URI: $SNIFFER_IMAGE_URI_FROM_METADATA"
echo "  GCP_PROJECT_ID:    $VM_GCP_PROJECT_ID_FROM_METADATA"
echo "  INCOMING_BUCKET:   $VM_INCOMING_BUCKET_FROM_METADATA"
echo "  PUBSUB_TOPIC_ID:   $VM_PUBSUB_TOPIC_ID_FROM_METADATA"
echo "  VM_SNIFFER_ID:     $VM_SNIFFER_ID_FROM_METADATA"

# Validate that all required metadata was successfully retrieved
if [ -z "$SNIFFER_IMAGE_URI_FROM_METADATA" ] || \
   [ -z "$VM_GCP_PROJECT_ID_FROM_METADATA" ] || \
   [ -z "$VM_INCOMING_BUCKET_FROM_METADATA" ] || \
   [ -z "$VM_PUBSUB_TOPIC_ID_FROM_METADATA" ] || \
   [ -z "$VM_SNIFFER_ID_FROM_METADATA" ]; then
  echo "FATAL ERROR: One or more required metadata attributes were not retrieved. Exiting."
  exit 1
fi

echo "Installing necessary packages (curl, jq, docker, docker-compose, tcpdump, tcpreplay, git, wget)..."
apt-get update -y
apt-get install -y --no-install-recommends curl jq docker.io docker-compose tcpdump tcpreplay git wget

echo "Starting and enabling Docker service..."
systemctl start docker
systemctl enable docker

# Check if the sniffer image URI points to Google Artifact Registry
if [[ "$SNIFFER_IMAGE_URI_FROM_METADATA" == *pkg.dev* ]]; then
  echo "Sniffer image appears to be from Artifact Registry. Configuring Docker authentication..."
  # Extract the Artifact Registry domain (e.g., europe-west8-docker.pkg.dev)
  ARTIFACT_REGISTRY_DOMAIN=$(echo "$SNIFFER_IMAGE_URI_FROM_METADATA" | cut -d'/' -f1)
  if [[ -z "$ARTIFACT_REGISTRY_DOMAIN" ]]; then
      echo "ERROR: Could not extract Artifact Registry domain from '$SNIFFER_IMAGE_URI_FROM_METADATA'"
      exit 1
  fi
  echo "Detected Artifact Registry domain: $ARTIFACT_REGISTRY_DOMAIN"
  # Configure Docker to use the VM's attached Service Account for authentication.
  # The VM's Service Account (test_vm_sa) needs 'roles/artifactregistry.reader' permission.
  if ! gcloud auth configure-docker "$ARTIFACT_REGISTRY_DOMAIN" -q; then # -q for quiet
      echo "ERROR: Failed to configure Docker for Artifact Registry domain: $ARTIFACT_REGISTRY_DOMAIN."
      echo "Ensure the VM's Service Account has 'roles/artifactregistry.reader' permission."
      echo "Active Service Account on VM:"
      gcloud auth list
      # Consider exiting if pull from private AR is critical and auth fails.
  else
      echo "Docker authentication configured for Artifact Registry: $ARTIFACT_REGISTRY_DOMAIN."
  fi
else
  echo "Sniffer image does not appear to be from Artifact Registry (e.g., Docker Hub). No specific Docker auth configured."
fi

echo "Pulling sniffer Docker image: $SNIFFER_IMAGE_URI_FROM_METADATA"
if ! docker pull "$SNIFFER_IMAGE_URI_FROM_METADATA"; then
  echo "ERROR: Failed to pull Docker image '$SNIFFER_IMAGE_URI_FROM_METADATA'."
  echo "Verify the image URI is correct, the image exists, and permissions are adequate (if it's a private registry)."
  exit 1
fi
echo "Sniffer Docker image pulled successfully."

# Define standard paths for sniffer configuration and SA key on the VM host
SNIFFER_PREP_DIR="/opt/sniffer_env"                 # Base directory for sniffer config files on VM
SNIFFER_ENV_FILE="$SNIFFER_PREP_DIR/.env"           # .env file for docker-compose
SNIFFER_COMPOSE_FILE_ON_VM="$SNIFFER_PREP_DIR/docker-compose.yml" # Base compose file on VM
SNIFFER_OVERRIDE_COMPOSE_FILE_ON_VM="$SNIFFER_PREP_DIR/docker-compose.override.yml" # Override compose file on VM

# Standard host path where the user is expected to copy the SA key file (key.json)
VM_HOST_KEY_DIR="/opt/gcp_sa_keys/sniffer"
# Path inside the sniffer container where the SA key will be mounted (as expected by sniffer_entrypoint.sh)
SNIFFER_GCP_KEY_CONTAINER_PATH="/app/gcp-key"
# Host path for PCAP captures, relative to SNIFFER_PREP_DIR when used in override file
CAPTURES_HOST_VOL_ON_VM="$SNIFFER_PREP_DIR/captures_host_vol"

echo "Creating directories for sniffer configuration (if they don't exist): $SNIFFER_PREP_DIR"
mkdir -p "$SNIFFER_PREP_DIR"
mkdir -p "$CAPTURES_HOST_VOL_ON_VM" # Create the host directory for captures volume

echo "Creating host directory for the sniffer's GCP Service Account key: $VM_HOST_KEY_DIR"
mkdir -p "$VM_HOST_KEY_DIR"
# Set open permissions on this directory to allow the user to easily scp the key file.
# This is acceptable for a test environment. For production, manage permissions more strictly.
chmod 777 "$VM_HOST_KEY_DIR"
echo "Permissions for $VM_HOST_KEY_DIR set to 777."

echo "Creating .env file for the sniffer in $SNIFFER_ENV_FILE"
# This .env file will be used by docker-compose to set environment variables inside the sniffer container.
cat << EOF_ENV > "$SNIFFER_ENV_FILE"
GCP_PROJECT_ID=$VM_GCP_PROJECT_ID_FROM_METADATA
INCOMING_BUCKET=$VM_INCOMING_BUCKET_FROM_METADATA
PUBSUB_TOPIC_ID=$VM_PUBSUB_TOPIC_ID_FROM_METADATA
SNIFFER_ID=${VM_SNIFFER_ID_FROM_METADATA}
# GCP_KEY_FILE is the path *inside* the container where sniffer_entrypoint.sh expects the key.
GCP_KEY_FILE=${SNIFFER_GCP_KEY_CONTAINER_PATH}/key.json
# Optional: Uncomment and customize tshark rotation or interface if needed.
# ROTATE=-b filesize:5120 # Example: Rotate every 5MB
# INTERFACE=eth0 # The sniffer_entrypoint.sh should auto-detect the primary active interface.
EOF_ENV
echo ".env file created successfully in $SNIFFER_ENV_FILE"

echo "Creating base docker-compose.yml for VM in $SNIFFER_COMPOSE_FILE_ON_VM"
# This base compose file on the VM will specify the image pulled from metadata.
# It does NOT include 'build' context, as the image is pre-pulled.
cat << EOF_BASE_COMPOSE > "$SNIFFER_COMPOSE_FILE_ON_VM"
version: '3.7' # Specify your preferred Docker Compose version
services:
  sniffer:
    image: "$SNIFFER_IMAGE_URI_FROM_METADATA" # Use the exact image URI that was pulled
    container_name: chronicle-sniffer-instance # Standardized container name
    restart: unless-stopped
    env_file:
      - .env # Loads .env from /opt/sniffer_env/ on the VM
    # Network mode, capabilities, and volumes will be defined in the override file.
EOF_BASE_COMPOSE
echo "Base docker-compose.yml created successfully in $SNIFFER_COMPOSE_FILE_ON_VM."


echo "Creating docker-compose.override.yml for VM-specific settings in $SNIFFER_OVERRIDE_COMPOSE_FILE_ON_VM"
# This override file adds VM-specific configurations like volumes and network mode
# to the base 'sniffer' service defined in docker-compose.yml.
cat << EOF_OVERRIDE_COMPOSE > "$SNIFFER_OVERRIDE_COMPOSE_FILE_ON_VM"
version: '3.7' # Must match the base compose file's version for proper merging
services:
  sniffer: # Must match the service name in the base compose file
    network_mode: "host"
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      # Mount the SA key from the standard VM host path to the container path
      - "${VM_HOST_KEY_DIR}:${SNIFFER_GCP_KEY_CONTAINER_PATH}:ro"
      # Mount the captures volume. './captures_host_vol' is relative to the override file's location
      # on the VM, which is /opt/sniffer_env/. So this resolves to /opt/sniffer_env/captures_host_vol.
      - "./captures_host_vol:/app/captures"
EOF_OVERRIDE_COMPOSE
echo "docker-compose.override.yml created successfully in $SNIFFER_OVERRIDE_COMPOSE_FILE_ON_VM."
    
echo "--- VM Startup Script Completed Successfully ---"
echo ""
echo "Sniffer environment prepared in: $SNIFFER_PREP_DIR"
echo "The 'docker-compose.yml' and 'docker-compose.override.yml' in '$SNIFFER_PREP_DIR' are configured for the VM."
echo "The sniffer will use the image: '$SNIFFER_IMAGE_URI_FROM_METADATA'."
echo ""
echo "To run the sniffer, the GCP Service Account key file ('key.json') must be copied to '${VM_HOST_KEY_DIR}/key.json' on this VM."
echo "For complete instructions, refer to the 'test_vm_sniffer_setup_instructions' output from Terraform."