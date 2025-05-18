# processor/json2udm_cloud.py - UDM Conversion Script (my cybersecurity proposal part)
# Original script adapted for memory-efficient streaming processing in Cloud Run:
# - Switched from `json.loads()` to `ijson` for streaming JSON parsing to handle large TShark output files without loading everything into memory.
# - Processes packets one by one, reducing peak memory usage.
# - Ensures every input packet results in a UDM event, even if it's a minimal error event.
# - Implemented a more robust timestamp conversion (`convert_timestamp_robust`) with fallbacks.
# - The UDM structure is now more aligned with Chronicle's expectations (metadata, principal, target, network sections clearly defined).
# - Removed the `write_to_multiple_files` function. In a cloud environment, the plan is to stream/send these UDM events directly to Chronicle's API or stage them in GCS.

import json
import sys
import os
import logging
from datetime import datetime, timezone
import ijson  # Added ijson for efficient streaming of large JSON files

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

def convert_timestamp_robust(timestamp_str):
    """
    Converts Wireshark timestamp string to ISO 8601 UTC format.
    If conversion fails, logs a warning and uses the current processing time as a robust fallback.
    This ensures a timestamp is always present in the UDM event.
    This is a significant improvement over the previous simple strptime, adding resilience.
    """
    if not timestamp_str:
        logging.warning(f"Timestamp string is missing or empty. Using current time as fallback.")
        return datetime.now(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')
    try:
        # Standard TShark format up to microseconds
        dt_naive = datetime.strptime(timestamp_str[:26], "%b %d, %Y %H:%M:%S.%f")
    except ValueError:
        # Fallback for timestamps that might not have microseconds or have timezone names
        try:
            # Attempt to clean common timezone strings if present
            cleaned_ts = timestamp_str.split(" UTC")[0]
            cleaned_ts = cleaned_ts.split(" Central European Summer Time")[0].strip() # Example, can add more
            dt_naive = datetime.strptime(cleaned_ts, "%b %d, %Y %H:%M:%S") # Try without microseconds
        except ValueError as e_fallback:
            logging.warning(f"Error converting timestamp '{timestamp_str}' with primary and fallback formats: {e_fallback}. Using current time.")
            # If all fails, use current time to ensure UDM compliance for event_timestamp
            return datetime.now(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')

    dt_aware = dt_naive.replace(tzinfo=timezone.utc) # Assume UTC as per Wireshark's frame.time_utc
    iso_timestamp = dt_aware.isoformat(timespec='microseconds').replace('+00:00', 'Z') # Ensure 'Z' for Zulu time
    return iso_timestamp

def get_nested_value(data_dict, key_path, default=None):
    """
    Safely retrieves a nested value from a dictionary using a dot-separated path.
    This helper avoids multiple .get() calls and KeyError exceptions, making data extraction cleaner
    than in the previous version where missing keys could lead to skipping packets or more verbose checks.
    """
    keys = key_path.split('.')
    val = data_dict
    try:
        for key in keys:
            if isinstance(val, dict):
                val = val.get(key)
            elif isinstance(val, list) and key.isdigit(): # Basic list index access
                idx = int(key)
                if 0 <= idx < len(val):
                    val = val[idx]
                else:
                    return default
            else:
                return default
            if val is None: # If any key in the path is not found or its value is None
                return default
        return val if val is not None else default
    except (TypeError, AttributeError, ValueError): # Catch errors if structure is not as expected
        return default

def extract_values_from_tshark_section(section_data, field_key):
    """
    Extracts all occurrences of 'field_key' from TShark's structured sections (e.g., DNS Queries/Answers).
    TShark often structures these as dicts of dicts.
    This is more generic than the previous `print_dns` specific functions.
    """
    values = []
    if isinstance(section_data, dict):
        # TShark's DNS query/answer sections are dictionaries of items where each item is another dictionary containing the actual fields.
        for item_details in section_data.values(): # Iterate through the inner dictionaries
            if isinstance(item_details, dict):
                value = item_details.get(field_key)
                if value is not None:
                    values.append(value)
    return values if values else None # Return None if no values found, to avoid empty lists in UDM

# --- Main Packet Conversion Logic ---
def convert_single_packet_to_udm(packet_data):
    """
    Converts a single packet (Python dictionary from ijson) to UDM format.
    A key design choice here is to ALWAYS produce a UDM event, even for malformed packets,
    to ensure no data is silently lost and to provide traceability.
    The UDM structure is more detailed and organized (principal, target, etc.) compared to the old script.
    """
    try:
        # The core data is nested under "_source" and "layers" in TShark's JSON output
        layers = packet_data.get("_source", {}).get("layers", {})
        packet_num_info = get_nested_value(packet_data, "_source.layers.frame.frame.number", "N/A")

        if not layers:
            # If the essential 'layers' key is missing, it's a severely malformed packet: create a minimal UDM event indicating this issue.
            logging.warning(f"Packet (num: {packet_num_info}) missing '_source.layers'. Creating minimal UDM.")
            ts_fallback = datetime.now(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')
            return {"event": {"metadata": {"event_timestamp": ts_fallback,
                                          "product_name": "Wireshark TShark (Malformed)", # Specific product name for this case
                                          "vendor_name": "Wireshark",
                                          "event_type": "NETWORK_EVENT_UNKNOWN", # Generic, as we know little
                                          "description": f"Malformed packet data. Frame: {packet_num_info}"}}}

        # Extract common layers. Using .get() for safety.
        frame = layers.get("frame", {})
        eth = layers.get("eth", {})
        ip = layers.get("ip", {})
        ipv6 = layers.get("ipv6", {}) # Added for completeness
        tcp = layers.get("tcp", {})
        udp = layers.get("udp", {})
        icmp = layers.get("icmp", {})
        dns = layers.get("dns", {})
        http = layers.get("http", {})
        tls_layer = layers.get("tls", {}) # Renamed from 'tls' to avoid conflict with the module
        arp = layers.get("arp", {})

        # Use the robust timestamp conversion for the primary event time
        event_timestamp = convert_timestamp_robust(frame.get("frame.time_utc"))

        # Initialize UDM sections. This structured approach is cleaner than the previous script's flat network dict.
        udm_principal = {}
        udm_target = {}
        udm_network = {}
        udm_about = [] # For entities like URLs or hostnames observed
        udm_additional = {} # For miscellaneous, non-standard UDM fields
        app_layer_data = {} # To hold specific L7 protocol data (HTTP, DNS, TLS)
        event_type = "NETWORK_CONNECTION" # Default event type

        # --- IP Layer (Principal and Target) ---
        if ip:
            udm_principal["ip"] = ip.get("ip.src")
            udm_target["ip"] = ip.get("ip.dst")
            udm_network["ip_protocol_version"] = 4
            if ip.get("ip.ttl") is not None: udm_additional["ip_ttl"] = str(ip.get("ip.ttl")) # Store TTL in additional
        elif ipv6: # Handle IPv6
            udm_principal["ip"] = ipv6.get("ipv6.src")
            udm_target["ip"] = ipv6.get("ipv6.dst")
            udm_network["ip_protocol_version"] = 6
        
        if eth: # MAC addresses
            udm_principal["mac"] = eth.get("eth.src")
            udm_target["mac"] = eth.get("eth.dst")

        # --- Transport Layer ---
        if tcp:
            udm_network["transport_protocol"] = "TCP"
            if tcp.get("tcp.srcport") is not None: udm_principal["port"] = int(tcp.get("tcp.srcport"))
            if tcp.get("tcp.dstport") is not None: udm_target["port"] = int(tcp.get("tcp.dstport"))
            if tcp.get("tcp.flags") is not None: udm_network["tcp_flags"] = tcp.get("tcp.flags") # Storing raw flags
        elif udp:
            udm_network["transport_protocol"] = "UDP"
            if udp.get("udp.srcport") is not None: udm_principal["port"] = int(udp.get("udp.srcport"))
            if udp.get("udp.dstport") is not None: udm_target["port"] = int(udp.get("udp.dstport"))
        elif icmp:
            udm_network["transport_protocol"] = "ICMP"
            event_type = "NETWORK_ICMP" # More specific event type
            if icmp.get("icmp.type") is not None: udm_network["icmp_type"] = str(icmp.get("icmp.type"))
            if icmp.get("icmp.code") is not None: udm_network["icmp_code"] = str(icmp.get("icmp.code"))
        elif arp: # ARP is L2/L3 but distinct, good to capture
            event_type = "NETWORK_ARP"
            # ARP specific details, mapping them to UDM principal/target where appropriate
            udm_additional["arp_operation"] = arp.get("arp.opcode") # e.g., request (1), reply (2)
            udm_principal["mac"] = arp.get("arp.src.hw_mac")
            udm_principal["ip"] = arp.get("arp.src.proto_ipv4") # Sender IP
            udm_target["mac"] = arp.get("arp.dst.hw_mac")
            udm_target["ip"] = arp.get("arp.dst.proto_ipv4")   # Target IP
        
        # --- Application Layer Protocols ---
        # This section is more structured for adding application data than the previous version.
        if http:
            event_type = "NETWORK_HTTP"
            http_info = {}
            if http.get("http.host"): 
                http_info["host"] = http.get("http.host")
                udm_about.append({"hostname": http.get("http.host")})
            if http.get("http.file_data"): http_info["file_data"] = http.get("http.file_data") # Potentially large, use with care
            if http.get("http.request.method"): http_info["method"] = http.get("http.request.method")
            if http.get("http.request.full_uri"): 
                http_info["url"] = http.get("http.request.full_uri")
                udm_about.append({"url": http_info["url"]})
            if http.get("http.user_agent"): http_info["user_agent"] = http.get("http.user_agent")
            if http.get("http.response.code"): http_info["status_code"] = int(http.get("http.response.code"))
            if http_info: app_layer_data["http"] = http_info
        
        # DNS processing, using the new helper `extract_values_from_tshark_section`, TShark's DNS JSON can be a bit nested.
        dns_source_layer = dns # Could also be layers.get("mdns") if we were handling that separately.
        if dns_source_layer:
            event_type = "NETWORK_DNS"
            dns_info = {}
            queries_section = dns_source_layer.get("Queries")
            if queries_section:
                q_names = extract_values_from_tshark_section(queries_section, "dns.qry.name")
                q_types = extract_values_from_tshark_section(queries_section, "dns.qry.type") # e.g., A, AAAA, CNAME
                if q_names:
                    dns_info["queries"] = []
                    for i, name in enumerate(q_names):
                        query_item = {"name": name}
                        if q_types and i < len(q_types): query_item["type"] = q_types[i]
                        dns_info["queries"].append(query_item)
                        udm_about.append({"hostname": name})

            # Answers section, similar structure
            answers_section = dns_source_layer.get("Answers")
            if answers_section:
                ans_ttls = extract_values_from_tshark_section(answers_section, "dns.resp.ttl")
                if ans_ttls: dns_info["answer_ttls"] = [int(t) for t in ans_ttls if t is not None]
                # For a full DNS UDM, would extract dns.a, dns.aaaa, dns.cname etc. here.

            # DNS Flags
            flags_tree = dns_source_layer.get("dns.flags_tree", {}) # TShark often puts flags in a sub-tree
            if flags_tree.get("dns.flags.response") is not None:
                dns_info["is_response"] = flags_tree.get("dns.flags.response") == '1' # '1' for response, '0' for query
            
            if dns_info: app_layer_data["dns"] = dns_info

        # TLS/SSL Information
        if tls_layer:
            event_type = "NETWORK_SSL" # UDM type for SSL/TLS events
            tls_info = {}
            # TShark can output tls.record as a single dict or a list of dicts (for multiple records in one TCP segment)
            tls_record_data = tls_layer.get("tls.record") 
            
            record_to_analyze = None
            if isinstance(tls_record_data, dict):
                record_to_analyze = tls_record_data
            elif isinstance(tls_record_data, list) and len(tls_record_data) > 0:
                record_to_analyze = tls_record_data[0] # Just take the first record for simplicity

            if record_to_analyze:
                if record_to_analyze.get("tls.record.version"): # e.g., "TLS 1.2" (0x0303)
                    tls_info["record_version_protocol"] = record_to_analyze.get("tls.record.version") 
                
                # Handshake data is often nested
                handshake_data = record_to_analyze.get("tls.handshake", {})
                if handshake_data.get("tls.handshake.version"):
                    tls_info["handshake_protocol_version"] = handshake_data.get("tls.handshake.version")
                
                # SNI (Server Name Indication) is a key field
                sni = get_nested_value(handshake_data, "tls.handshake.extensions_server_name")
                if sni:
                    tls_info["server_name_indication"] = sni
                    udm_about.append({"hostname": sni}) # SNI is a good candidate for 'about'
            
            if tls_info: app_layer_data["tls"] = tls_info

        # --- Constructing the UDM Event ---
        udm_payload = {
            "metadata": {
                "event_timestamp": event_timestamp,
                "product_name": "Wireshark TShark",
                "vendor_name": "Wireshark",
                "event_type": event_type, # Dynamically set based on protocols found
                "description": f"Packet capture. Protocols: {frame.get('frame.protocols', 'N/A')}. Frame No: {packet_num_info}"
            }
        }

        # Helper to remove None values before adding to UDM, keeps the output clean
        def clean_none_values(d): return {k: v for k, v in d.items() if v is not None}

        # Add sections to UDM only if they have content
        cleaned_principal = clean_none_values(udm_principal)
        if cleaned_principal: udm_payload["principal"] = cleaned_principal
        
        cleaned_target = clean_none_values(udm_target)
        if cleaned_target: udm_payload["target"] = cleaned_target

        # Special check for ip_protocol_version before cleaning, as it might be 0 if not IP
        if udm_network.get("ip_protocol_version") is None: # Check before cleaning
            udm_network.pop("ip_protocol_version", None) # Avoid "ip_protocol_version": null
        cleaned_network = clean_none_values(udm_network)
        if cleaned_network: udm_payload["network"] = cleaned_network
        
        # Clean 'about' list: remove empty dicts or dicts where all values are None
        cleaned_about = [item for item in udm_about if item and any(item.values())]
        if cleaned_about: udm_payload["about"] = cleaned_about
        
        if app_layer_data: # If we collected any L7 data
            if "network" not in udm_payload: udm_payload["network"] = {} # Ensure network section exists
            udm_payload["network"]["application_protocol_data"] = app_layer_data
        
        cleaned_additional = clean_none_values(udm_additional)
        if cleaned_additional: udm_payload["additional"] = cleaned_additional

        # The final UDM event is wrapped in an "event" key, as expected by some ingestion APIs
        return {"event": udm_payload}

    except Exception as e_packet_processing:
        # This is a catch-all for unexpected errors during a single packet's processing.
        # The goal is to still create a UDM event describing the error.
        packet_num_info = get_nested_value(packet_data, "_source.layers.frame.frame.number", "N/A (error state)")
        ts_fallback = datetime.now(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')
        logging.error(f"Critical error processing packet (num: {packet_num_info}): {e_packet_processing}. Creating minimal UDM event.", exc_info=True)
        
        # Try to get a snippet of the problematic packet for debugging, without crashing if serialization fails
        try:
            packet_snippet = json.dumps(packet_data) # This could be large
            if len(packet_snippet) > 1000: # Limit snippet size
                 packet_snippet = packet_snippet[:1000] + "..."
        except Exception:
            packet_snippet = "Could not serialize packet data for snippet."

        return {"event": {"metadata": {"event_timestamp": ts_fallback,
                                      "product_name": "Wireshark TShark (PacketProcessingError)", # Differentiate error source
                                      "vendor_name": "Wireshark",
                                      "event_type": "NETWORK_EVENT_ERROR", # Specific error type
                                      "description": f"Error during UDM conversion for packet. Frame No: {packet_num_info}. Error: {str(e_packet_processing)}"},
                         "additional": {"processing_error_message": str(e_packet_processing), # Store the error message
                                        "original_packet_data_snippet": packet_snippet}}} # And the snippet

def json_to_udm_streaming(json_file_path):
    """
    Processes a JSON file line by line (streaming objects from a JSON array) using ijson.
    This is the core change for memory efficiency compared to the old script's `json.loads()`
    which loaded the entire file into memory.
    """
    udm_events_list = [] # Will hold all converted UDM events for this run
    processed_packet_count = 0
    error_event_count = 0 # Count of packets that resulted in an error UDM

    try:
        # 'rb' mode is important for ijson as it handles its own decoding
        with open(json_file_path, 'rb') as f_json: 
            # `ijson.items(f_json, 'item')` assumes the JSON is an array of objects at the root.
            # 'item' tells ijson to yield each element of that root array.
            json_packet_iterator = ijson.items(f_json, 'item') 
            for packet_data_dict in json_packet_iterator:
                # The variable `udm_event` was referred to as `udt_event` in some old comments, corrected.
                udm_event = convert_single_packet_to_udm(packet_data_dict)
                udm_events_list.append(udm_event)
                processed_packet_count += 1
                # Check if the generated UDM event was an error event
                if "PacketProcessingError" in udm_event.get("event", {}).get("metadata", {}).get("product_name", ""):
                    error_event_count += 1
        
        logging.info(f"Successfully converted {processed_packet_count} packets from JSON to UDM format.")
        if error_event_count > 0:
            logging.warning(f"{error_event_count} packets encountered processing errors and were converted to minimal error UDM events.")
            
    except ijson.JSONError as e_ijson:
        # This catches errors during the streaming parse itself (e.g., malformed JSON structure)
        logging.error(f"ijson.JSONError while parsing streaming JSON from {json_file_path}: {e_ijson}. File may be malformed or not a JSON array at the root.", exc_info=True)
        return [] # Return empty list on parsing failure
    except FileNotFoundError:
        logging.error(f"Input JSON file for streaming not found: {json_file_path}")
        return []
    except Exception as e_streaming_outer:
        # Catch any other unexpected errors during the streaming process
        logging.error(f"Unexpected error during streaming conversion of {json_file_path}: {e_streaming_outer}", exc_info=True)
        return []

    return udm_events_list # This list is then written to a single output file.

if __name__ == "__main__":
    if len(sys.argv) != 3:
        logging.error("Usage: python3 json2udm_cloud.py <input_json_file> <output_udm_file>")
        sys.exit(1)
    
    input_file_path = sys.argv[1]
    output_file_path = sys.argv[2]

    if not os.path.isfile(input_file_path):
        logging.error(f"Error: Input JSON file '{input_file_path}' not found.")
        sys.exit(1)
    
    # Log file size for context, helpful for understanding performance/memory with large files.
    try:
        file_size_mb = os.path.getsize(input_file_path) / (1024 * 1024)
        logging.info(f"Starting UDM conversion for JSON file: {input_file_path} (Size: {file_size_mb:.2f} MB)")
    except Exception as e_stat: # Catch potential errors like permission denied
        logging.warning(f"Could not get size of input file {input_file_path}: {e_stat}")

    # Core conversion logic using the streaming approach
    udm_event_list_result = json_to_udm_streaming(input_file_path)

    # Outputting to a single file. The previous script had `write_to_multiple_files` which isn't needed here, 
    # as the next step in a GCP environment would likely be to upload this single file to GCS or send its contents via API to Chronicle.
    # If this list becomes too large for memory before writing, the streaming output would need to be to the file directly.
    try:
        # Ensure output directory exists, especially if output_file_path includes subdirectories
        output_directory = os.path.dirname(output_file_path)
        if output_directory and not os.path.exists(output_directory): # Check if dirname is not empty
            os.makedirs(output_directory, exist_ok=True)
            logging.info(f"Created output directory: {output_directory}")
        
        with open(output_file_path, "w") as f_out: # 'w' for text mode, as json.dump expects string data
            json.dump(udm_event_list_result, f_out, indent=4) # Pretty print for readability
        
        if udm_event_list_result: # Only log success if events were actually written
            logging.info(f"Successfully wrote {len(udm_event_list_result)} UDM events to {output_file_path}")
        else:
            # This case covers ijson errors or if the input JSON was empty/invalid leading to no UDM events
            logging.warning(f"No UDM events were generated (or stream parsing failed). Wrote an empty list to {output_file_path}.")
            
    except Exception as e_write:
        # This is a critical error if we can't even write the output.
        logging.critical(f"CRITICAL ERROR: Failed to write UDM output to '{output_file_path}': {e_write}", exc_info=True)
        sys.exit(1) # Exit with error if output fails

    sys.exit(0) # Successful execution
