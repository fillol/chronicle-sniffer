# processor/json2udm_cloud.py - Script di conversione UDM (parte della mia proposta originale)

import json
import sys
import os
import logging
from datetime import datetime, timezone

# Configure logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

# Convert timestamp to RFC 3339 format (ISO 8601)
def convert_timestamp(timestamp_str):
    """Converts Wireshark timestamp string to ISO 8601 UTC format."""
    try:
        try:
             dt_naive = datetime.strptime(timestamp_str[:26], "%b %d, %Y %H:%M:%S.%f")
        except ValueError:
             dt_naive = datetime.strptime(timestamp_str.split(" UTC")[0], "%b %d, %Y %H:%M:%S") # Prova senza microsecondi e rimuovendo UTC alla fine

        dt_aware = dt_naive.replace(tzinfo=timezone.utc)
        iso_timestamp = dt_aware.isoformat(timespec='microseconds')
        if iso_timestamp.endswith('+00:00'):
             iso_timestamp = iso_timestamp[:-6] + 'Z'
        return iso_timestamp
    except Exception as e:
        logging.warning(f"Error converting timestamp '{timestamp_str}': {e}. Using current time.")
        return datetime.now(timezone.utc).isoformat(timespec='microseconds') + 'Z'

# Helper function to safely extract nested dictionary values for DNS
def get_dns_value(data_dict, key_path):
    """Safely retrieves a nested value from a dictionary using a dot-separated path."""
    keys = key_path.split('.')
    val = data_dict
    try:
        for key in keys:
            if isinstance(val, dict): val = val.get(key)
            elif isinstance(val, list) and key.isdigit(): val = val[int(key)]
            else: return None
            if val is None: return None
        return val
    except: return None

# Helper function to extract DNS query/answer details
def extract_dns_details(dns_layer, detail_type):
    """Extracts specific details from DNS queries or answers."""
    details = {}
    data_section = None
    if detail_type == "query" and "Queries" in dns_layer: data_section = dns_layer["Queries"]
    if detail_type == "answer" and "Answers" in dns_layer: data_section = dns_layer["Answers"]

    if data_section and isinstance(data_section, dict):
        for item_id, item_data in data_section.items():
            if isinstance(item_data, dict):
                if detail_type == "query":
                    name = item_data.get("dns.qry.name")
                    q_type = item_data.get("dns.qry.type")
                    if name: details["name"] = name
                    if q_type: details["type"] = q_type
                elif detail_type == "answer":
                    ttl = item_data.get("dns.resp.ttl")
                    # Potrebbe esserci anche dns.resp.name, dns.a, dns.aaaa etc.
                    if ttl: details["ttl"] = ttl
                if details: break # Prendi solo il primo trovato

    # Extract flags if available
    flags_tree = dns_layer.get("dns.flags_tree")
    if isinstance(flags_tree, dict):
        response_flag = flags_tree.get("dns.flags.response")
        if response_flag is not None:
             details["flags_response"] = response_flag == '1'

    return details if details else None

# Helper function to extract TLS handshake details
def extract_tls_handshake(tls_record, item_key):
    """Safely extracts handshake details from a TLS record."""
    if isinstance(tls_record, dict):
        handshake = tls_record.get("tls.handshake")
        if isinstance(handshake, dict):
            return handshake.get(item_key)
    return None

# Function to convert JSON packet data to UDM format
def json_to_udm(wireshark_json_str):
    """Converts a string containing Wireshark JSON export to a list of UDM events."""
    try:
        packets = json.loads(wireshark_json_str)
        if not isinstance(packets, list):
             if isinstance(packets, dict): packets = [packets]
             else: logging.error("Input JSON is not a list or a dictionary."); return []
    except json.JSONDecodeError as e: logging.error(f"Error decoding input JSON: {e}"); return []
    except Exception as e: logging.error(f"Unexpected error loading JSON: {e}"); return []

    udm_events = []
    total_events_processed = 0
    skipped_packets = 0

    for packet in packets:
        try:
            if not isinstance(packet, dict) or "_source" not in packet or "layers" not in packet["_source"]:
                logging.warning(f"Skipping packet due to unexpected structure.")
                skipped_packets += 1; continue
            layers = packet["_source"]["layers"]

            frame = layers.get("frame", {}); eth = layers.get("eth", {}); ip = layers.get("ip", {})
            ipv6 = layers.get("ipv6", {}); tcp = layers.get("tcp", {}); udp = layers.get("udp", {})
            icmp = layers.get("icmp", {}); dns = layers.get("dns", {}); http = layers.get("http", {})
            tls = layers.get("tls", {}); arp = layers.get("arp",{})

            event_timestamp = convert_timestamp(frame.get("frame.time_utc")) if frame.get("frame.time_utc") else None
            if not event_timestamp:
                 logging.warning(f"Skipping packet due to missing/invalid timestamp: {frame.get('frame.time_utc')}")
                 skipped_packets += 1; continue

            udm_event = {
                "metadata": {
                    "event_timestamp": event_timestamp, "product_name": "Wireshark TShark",
                    "vendor_name": "Wireshark", "event_type": "NETWORK_CONNECTION",
                    "description": f"Packet capture. Protocols: {frame.get('frame.protocols', 'N/A')}"
                },
                "principal": {}, "target": {}, "network": {}, "about": []
            }
            net = udm_event["network"]; principal = udm_event["principal"]; target = udm_event["target"]

            if tcp: net["transport_protocol"] = "TCP"
            elif udp: net["transport_protocol"] = "UDP"
            elif icmp: net["transport_protocol"] = "ICMP"
            elif arp: net["transport_protocol"] = "ARP"

            if ip:
                 principal["ip"] = ip.get("ip.src"); target["ip"] = ip.get("ip.dst")
                 net["ip_protocol_version"] = 4
            elif ipv6:
                 principal["ip"] = ipv6.get("ipv6.src"); target["ip"] = ipv6.get("ipv6.dst")
                 net["ip_protocol_version"] = 6

            if eth: principal["mac"] = eth.get("eth.src"); target["mac"] = eth.get("eth.dst")

            if tcp:
                 principal["port"] = int(tcp.get("tcp.srcport", 0)); target["port"] = int(tcp.get("tcp.dstport", 0))
                 net["tcp_flags"] = tcp.get("tcp.flags")
            elif udp:
                 principal["port"] = int(udp.get("udp.srcport", 0)); target["port"] = int(udp.get("udp.dstport", 0))

            if icmp:
                 net["icmp_type"] = icmp.get("icmp.type"); net["icmp_code"] = icmp.get("icmp.code")
                 udm_event["metadata"]["event_type"] = "NETWORK_ICMP"

            if arp:
                 udm_event["metadata"]["event_type"] = "NETWORK_ARP"
                 principal["mac"] = arp.get("arp.src.hw_mac"); principal["ip"] = arp.get("arp.src.proto_ipv4")
                 target["mac"] = arp.get("arp.dst.hw_mac"); target["ip"] = arp.get("arp.dst.proto_ipv4")

            app_layer = {}
            if http:
                 udm_event["metadata"]["event_type"] = "NETWORK_HTTP"
                 http_data = {k:v for k,v in {
                     "method": http.get("http.request.method"), "user_agent": http.get("http.user_agent"),
                     "url": http.get("http.request.full_uri"), "host": http.get("http.host"),
                     "status_code": int(http.get("http.response.code", 0)) if http.get("http.response.code") else None,
                     "referrer": http.get("http.referer"), "content_type": http.get("http.content_type"),
                     "request_body_bytes": int(http.get("http.content_length_header", 0)) if http.get("http.content_length_header") else None,
                     "response_body_bytes": int(http.get("http.content_length", 0)) if http.get("http.content_length") else None,
                     "file_data": http.get("http.file_data")}.items() if v is not None}
                 app_layer["http"] = http_data
                 if http_data.get("url"): udm_event["about"].append({"url": http_data["url"]})
                 elif http_data.get("host"): udm_event["about"].append({"hostname": http_data["host"]})

            if dns:
                 udm_event["metadata"]["event_type"] = "NETWORK_DNS"
                 query_details = extract_dns_details(dns, "query")
                 answer_details = extract_dns_details(dns, "answer")
                 flags = extract_dns_details(dns, "flags")
                 dns_data = {}
                 if query_details:
                     dns_data["query"] = query_details.get("name")
                     dns_data["question_type"] = query_details.get("type")
                     if query_details.get("name"): udm_event["about"].append({"hostname": query_details["name"]})
                 if answer_details: dns_data["response_ttl"] = answer_details.get("ttl")
                 if flags: dns_data["is_response"] = flags.get("flags_response")
                 if dns_data: app_layer["dns"] = dns_data

            if tls:
                 udm_event["metadata"]["event_type"] = "NETWORK_SSL"
                 record = tls.get("tls.record", {})
                 tls_data = {k:v for k,v in {
                     "version": extract_tls_handshake(record, "tls.handshake.version"),
                     "record_version": record.get("tls.record.version"),
                     "server_name_indication": extract_tls_handshake(record, "tls.handshake.extensions_server_name")}.items() if v is not None}
                 app_layer["tls"] = tls_data
                 if tls_data.get("server_name_indication"): udm_event["about"].append({"hostname": tls_data["server_name_indication"]})

            if app_layer: net["application_protocol_data"] = app_layer

            # Clean up empty sections
            udm_event["principal"] = {k: v for k, v in principal.items() if v is not None}
            udm_event["target"] = {k: v for k, v in target.items() if v is not None}
            udm_event["network"] = {k: v for k, v in net.items() if v is not None}
            udm_event["about"] = [item for item in udm_event["about"] if item]

            if not udm_event["principal"] and not udm_event["target"]:
                 logging.warning(f"Skipping packet - no principal or target info extracted.")
                 skipped_packets += 1; continue

            udm_events.append({"event": udm_event})
            total_events_processed += 1

        except KeyError as e: logging.warning(f"Skipping packet due to missing key: {e}."); skipped_packets += 1
        except Exception as e: logging.error(f"Unexpected error processing packet: {e}.", exc_info=True); skipped_packets += 1

    logging.info(f"Processed {total_events_processed} packets into UDM events.")
    if skipped_packets > 0: logging.warning(f"Skipped {skipped_packets} packets.")
    return udm_events

# --- Main Entry Point ---
if __name__ == "__main__":
    if len(sys.argv) != 3:
        logging.error("Usage: python3 json2udm_cloud.py <input_json_file> <output_udm_file>")
        sys.exit(1)
    input_file, output_file = sys.argv[1], sys.argv[2]

    if not os.path.isfile(input_file):
        logging.error(f"Error: Input file '{input_file}' not found.")
        sys.exit(1)

    try:
        logging.info(f"Reading input JSON file: {input_file}")
        with open(input_file, "r") as f: wireshark_json_content = f.read()
        logging.info(f"Read {len(wireshark_json_content)} bytes.")
    except Exception as e: logging.error(f"Error reading file '{input_file}': {e}"); sys.exit(1)

    udm_events_list = json_to_udm(wireshark_json_content)

    if udm_events_list:
        try:
            logging.info(f"Writing {len(udm_events_list)} UDM events to {output_file}")
            os.makedirs(os.path.dirname(output_file), exist_ok=True)
            with open(output_file, "w") as f: json.dump(udm_events_list, f, indent=4) # Pretty print
            logging.info(f"Successfully wrote UDM events to {output_file}")
        except Exception as e: logging.error(f"Error writing UDM output file '{output_file}': {e}"); sys.exit(1)
    else:
        logging.warning(f"No UDM events generated from {input_file}. No output file created.")

    sys.exit(0)
