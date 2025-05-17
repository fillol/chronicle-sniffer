# processor/json2udm_cloud.py - Script di conversione UDM (parte della mia proposta per cybersecurity)
# Original script adapted for memory-efficient streaming processing in Cloud Run.
# Key changes:
# - Uses ijson for streaming JSON parsing to handle large files.
# - Processes packets one by one, reducing peak memory usage.
# - Ensures every packet results in a UDM event, even if minimal (e.g., containing an error description).
# - Robust timestamp conversion with fallback to current time.
# - UDM structure aligned (with metadata, principal, target, network sections).
# - Corrected typos: udt_payload -> udm_payload, udt_event -> udm_event

import json
import sys
import os
import logging
from datetime import datetime, timezone
import ijson

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

def convert_timestamp_robust(timestamp_str):
    """
    Converts Wireshark timestamp string to ISO 8601 UTC format.
    If conversion fails, logs a warning and uses the current processing time as a robust fallback.
    This ensures a timestamp is always present in the UDM event.
    """
    if not timestamp_str:
        logging.warning(f"Timestamp string is missing or empty. Using current time as fallback.")
        return datetime.now(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')
    try:
        dt_naive = datetime.strptime(timestamp_str[:26], "%b %d, %Y %H:%M:%S.%f")
    except ValueError:
        try:
            cleaned_ts = timestamp_str.split(" UTC")[0]
            cleaned_ts = cleaned_ts.split(" Central European Summer Time")[0].strip() # Example
            dt_naive = datetime.strptime(cleaned_ts, "%b %d, %Y %H:%M:%S")
        except ValueError as e_fallback:
            logging.warning(f"Error converting timestamp '{timestamp_str}' with primary and fallback formats: {e_fallback}. Using current time.")
            return datetime.now(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')

    dt_aware = dt_naive.replace(tzinfo=timezone.utc)
    iso_timestamp = dt_aware.isoformat(timespec='microseconds').replace('+00:00', 'Z')
    return iso_timestamp

def get_nested_value(data_dict, key_path, default=None):
    """
    Safely retrieves a nested value from a dictionary using a dot-separated path.
    """
    keys = key_path.split('.')
    val = data_dict
    try:
        for key in keys:
            if isinstance(val, dict):
                val = val.get(key)
            elif isinstance(val, list) and key.isdigit():
                idx = int(key)
                if 0 <= idx < len(val):
                    val = val[idx]
                else:
                    return default
            else:
                return default
            if val is None:
                return default
        return val if val is not None else default
    except (TypeError, AttributeError, ValueError):
        return default

def extract_values_from_tshark_section(section_data, field_key):
    """
    Extracts all occurrences of 'field_key' from TShark's structured sections.
    """
    values = []
    if isinstance(section_data, dict):
        for item_details in section_data.values():
            if isinstance(item_details, dict):
                value = item_details.get(field_key)
                if value is not None:
                    values.append(value)
    return values if values else None

# --- Main Packet Conversion Logic ---
def convert_single_packet_to_udm(packet_data):
    """
    Converts a single packet (Python dictionary) to UDM format.
    """
    try:
        layers = packet_data.get("_source", {}).get("layers", {})
        packet_num_info = get_nested_value(packet_data, "_source.layers.frame.frame.number", "N/A")

        if not layers:
            logging.warning(f"Packet (num: {packet_num_info}) missing '_source.layers'. Creating minimal UDM.")
            ts_fallback = datetime.now(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')
            return {"event": {"metadata": {"event_timestamp": ts_fallback,
                                          "product_name": "Wireshark TShark (Malformed)",
                                          "vendor_name": "Wireshark",
                                          "event_type": "NETWORK_EVENT_UNKNOWN",
                                          "description": f"Malformed packet data. Frame: {packet_num_info}"}}}

        frame = layers.get("frame", {})
        eth = layers.get("eth", {})
        ip = layers.get("ip", {})
        ipv6 = layers.get("ipv6", {})
        tcp = layers.get("tcp", {})
        udp = layers.get("udp", {})
        icmp = layers.get("icmp", {})
        dns = layers.get("dns", {})
        http = layers.get("http", {})
        tls_layer = layers.get("tls", {})
        arp = layers.get("arp", {})

        event_timestamp = convert_timestamp_robust(frame.get("frame.time_utc"))

        udm_principal = {}
        udm_target = {}
        udm_network = {}
        udm_about = []
        udm_additional = {}
        app_layer_data = {}
        event_type = "NETWORK_CONNECTION"

        if ip:
            udm_principal["ip"] = ip.get("ip.src")
            udm_target["ip"] = ip.get("ip.dst")
            udm_network["ip_protocol_version"] = 4
            if ip.get("ip.ttl") is not None: udm_additional["ip_ttl"] = str(ip.get("ip.ttl"))
        elif ipv6:
            udm_principal["ip"] = ipv6.get("ipv6.src")
            udm_target["ip"] = ipv6.get("ipv6.dst")
            udm_network["ip_protocol_version"] = 6
        
        if eth:
            udm_principal["mac"] = eth.get("eth.src")
            udm_target["mac"] = eth.get("eth.dst")

        if tcp:
            udm_network["transport_protocol"] = "TCP"
            if tcp.get("tcp.srcport") is not None: udm_principal["port"] = int(tcp.get("tcp.srcport"))
            if tcp.get("tcp.dstport") is not None: udm_target["port"] = int(tcp.get("tcp.dstport"))
            if tcp.get("tcp.flags") is not None: udm_network["tcp_flags"] = tcp.get("tcp.flags")
        elif udp:
            udm_network["transport_protocol"] = "UDP"
            if udp.get("udp.srcport") is not None: udm_principal["port"] = int(udp.get("udp.srcport"))
            if udp.get("udp.dstport") is not None: udm_target["port"] = int(udp.get("udp.dstport"))
        elif icmp:
            udm_network["transport_protocol"] = "ICMP"
            event_type = "NETWORK_ICMP"
            if icmp.get("icmp.type") is not None: udm_network["icmp_type"] = str(icmp.get("icmp.type"))
            if icmp.get("icmp.code") is not None: udm_network["icmp_code"] = str(icmp.get("icmp.code"))
        elif arp:
            event_type = "NETWORK_ARP"
            udm_additional["arp_operation"] = arp.get("arp.opcode")
            udm_principal["mac"] = arp.get("arp.src.hw_mac")
            udm_principal["ip"] = arp.get("arp.src.proto_ipv4")
            udm_target["mac"] = arp.get("arp.dst.hw_mac")
            udm_target["ip"] = arp.get("arp.dst.proto_ipv4")
        
        if http:
            event_type = "NETWORK_HTTP"
            http_info = {}
            if http.get("http.host"): 
                http_info["host"] = http.get("http.host")
                udm_about.append({"hostname": http.get("http.host")})
            if http.get("http.file_data"): http_info["file_data"] = http.get("http.file_data")
            if http.get("http.request.method"): http_info["method"] = http.get("http.request.method")
            if http.get("http.request.full_uri"): 
                http_info["url"] = http.get("http.request.full_uri")
                udm_about.append({"url": http_info["url"]})
            if http.get("http.user_agent"): http_info["user_agent"] = http.get("http.user_agent")
            if http.get("http.response.code"): http_info["status_code"] = int(http.get("http.response.code"))
            if http_info: app_layer_data["http"] = http_info
        
        dns_source_layer = dns
        if dns_source_layer:
            event_type = "NETWORK_DNS"
            dns_info = {}
            queries_section = dns_source_layer.get("Queries")
            if queries_section:
                q_names = extract_values_from_tshark_section(queries_section, "dns.qry.name")
                q_types = extract_values_from_tshark_section(queries_section, "dns.qry.type")
                if q_names:
                    dns_info["queries"] = []
                    for i, name in enumerate(q_names):
                        query_item = {"name": name}
                        if q_types and i < len(q_types): query_item["type"] = q_types[i]
                        dns_info["queries"].append(query_item)
                        udm_about.append({"hostname": name})

            answers_section = dns_source_layer.get("Answers")
            if answers_section:
                ans_ttls = extract_values_from_tshark_section(answers_section, "dns.resp.ttl")
                if ans_ttls: dns_info["answer_ttls"] = [int(t) for t in ans_ttls if t is not None]

            flags_tree = dns_source_layer.get("dns.flags_tree", {})
            if flags_tree.get("dns.flags.response") is not None:
                dns_info["is_response"] = flags_tree.get("dns.flags.response") == '1'
            
            if dns_info: app_layer_data["dns"] = dns_info

        if tls_layer:
            event_type = "NETWORK_SSL"
            tls_info = {}
            tls_record_data = tls_layer.get("tls.record") 
            
            record_to_analyze = None
            if isinstance(tls_record_data, dict):
                record_to_analyze = tls_record_data
            elif isinstance(tls_record_data, list) and len(tls_record_data) > 0:
                record_to_analyze = tls_record_data[0]

            if record_to_analyze:
                if record_to_analyze.get("tls.record.version"): 
                    tls_info["record_version_protocol"] = record_to_analyze.get("tls.record.version") 
                
                handshake_data = record_to_analyze.get("tls.handshake", {})
                if handshake_data.get("tls.handshake.version"):
                    tls_info["handshake_protocol_version"] = handshake_data.get("tls.handshake.version")
                
                sni = get_nested_value(handshake_data, "tls.handshake.extensions_server_name")
                if sni:
                    tls_info["server_name_indication"] = sni
                    udm_about.append({"hostname": sni})
            
            if tls_info: app_layer_data["tls"] = tls_info

        udm_payload = {  # Defined udm_payload here
            "metadata": {
                "event_timestamp": event_timestamp,
                "product_name": "Wireshark TShark",
                "vendor_name": "Wireshark",
                "event_type": event_type,
                "description": f"Packet capture. Protocols: {frame.get('frame.protocols', 'N/A')}. Frame No: {packet_num_info}"
            }
        }

        def clean_none_values(d): return {k: v for k, v in d.items() if v is not None}

        cleaned_principal = clean_none_values(udm_principal)
        if cleaned_principal: udm_payload["principal"] = cleaned_principal # Use udm_payload
        
        cleaned_target = clean_none_values(udm_target)
        if cleaned_target: udm_payload["target"] = cleaned_target # Use udm_payload

        if udm_network.get("ip_protocol_version") is None: # Check before cleaning
            udm_network.pop("ip_protocol_version", None)
        cleaned_network = clean_none_values(udm_network)
        if cleaned_network: udm_payload["network"] = cleaned_network # Use udm_payload
        
        cleaned_about = [item for item in udm_about if item and any(item.values())]
        if cleaned_about: udm_payload["about"] = cleaned_about # Use udm_payload
        
        if app_layer_data:
            if "network" not in udm_payload: udm_payload["network"] = {} # Use udm_payload
            udm_payload["network"]["application_protocol_data"] = app_layer_data # Use udm_payload
        
        cleaned_additional = clean_none_values(udm_additional)
        if cleaned_additional: udm_payload["additional"] = cleaned_additional # Use udm_payload

        return {"event": udm_payload}

    except Exception as e_packet_processing:
        packet_num_info = get_nested_value(packet_data, "_source.layers.frame.frame.number", "N/A (error state)")
        ts_fallback = datetime.now(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')
        logging.error(f"Critical error processing packet (num: {packet_num_info}): {e_packet_processing}. Creating minimal UDM event.", exc_info=True)
        
        try:
            packet_snippet = json.dumps(packet_data)
            if len(packet_snippet) > 1000:
                 packet_snippet = packet_snippet[:1000] + "..."
        except Exception:
            packet_snippet = "Could not serialize packet data for snippet."

        return {"event": {"metadata": {"event_timestamp": ts_fallback,
                                      "product_name": "Wireshark TShark (PacketProcessingError)",
                                      "vendor_name": "Wireshark",
                                      "event_type": "NETWORK_EVENT_ERROR",
                                      "description": f"Error during UDM conversion for packet. Frame No: {packet_num_info}. Error: {str(e_packet_processing)}"},
                         "additional": {"processing_error_message": str(e_packet_processing),
                                        "original_packet_data_snippet": packet_snippet}}}

def json_to_udm_streaming(json_file_path):
    udm_events_list = []
    processed_packet_count = 0
    error_event_count = 0 

    try:
        with open(json_file_path, 'rb') as f_json: 
            json_packet_iterator = ijson.items(f_json, 'item') 
            for packet_data_dict in json_packet_iterator:
                udm_event = convert_single_packet_to_udm(packet_data_dict) # udm_event is defined here
                udm_events_list.append(udm_event)
                processed_packet_count += 1
                if "PacketProcessingError" in udm_event.get("event", {}).get("metadata", {}).get("product_name", ""): # Use udm_event
                    error_event_count += 1
        
        logging.info(f"Successfully converted {processed_packet_count} packets from JSON to UDM format.")
        if error_event_count > 0:
            logging.warning(f"{error_event_count} packets encountered processing errors and were converted to minimal error UDM events.")
            
    except ijson.JSONError as e_ijson:
        logging.error(f"ijson.JSONError while parsing streaming JSON from {json_file_path}: {e_ijson}. File may be malformed or not a JSON array at the root.", exc_info=True)
        return [] 
    except FileNotFoundError:
        logging.error(f"Input JSON file for streaming not found: {json_file_path}")
        return []
    except Exception as e_streaming_outer:
        logging.error(f"Unexpected error during streaming conversion of {json_file_path}: {e_streaming_outer}", exc_info=True)
        return []

    return udm_events_list

if __name__ == "__main__":
    if len(sys.argv) != 3:
        logging.error("Usage: python3 json2udm_cloud.py <input_json_file> <output_udm_file>")
        sys.exit(1)
    
    input_file_path = sys.argv[1]
    output_file_path = sys.argv[2]

    if not os.path.isfile(input_file_path):
        logging.error(f"Error: Input JSON file '{input_file_path}' not found.")
        sys.exit(1)
    
    try:
        file_size_mb = os.path.getsize(input_file_path) / (1024 * 1024)
        logging.info(f"Starting UDM conversion for JSON file: {input_file_path} (Size: {file_size_mb:.2f} MB)")
    except Exception as e_stat:
        logging.warning(f"Could not get size of input file {input_file_path}: {e_stat}")

    udm_event_list_result = json_to_udm_streaming(input_file_path)

    try:
        output_directory = os.path.dirname(output_file_path)
        if output_directory and not os.path.exists(output_directory):
            os.makedirs(output_directory, exist_ok=True)
            logging.info(f"Created output directory: {output_directory}")
        
        with open(output_file_path, "w") as f_out:
            json.dump(udm_event_list_result, f_out, indent=4)
        
        if udm_event_list_result:
            logging.info(f"Successfully wrote {len(udm_event_list_result)} UDM events to {output_file_path}")
        else:
            logging.warning(f"No UDM events were generated (or stream parsing failed). Wrote an empty list to {output_file_path}.")
            
    except Exception as e_write:
        logging.critical(f"CRITICAL ERROR: Failed to write UDM output to '{output_file_path}': {e_write}", exc_info=True)
        sys.exit(1)

    sys.exit(0)