#!/bin/bash

ZONE="test."
KNOT_SERVER="127.0.0.1"
KNOT_PORT="9053"

# Initialize variables
TSIG_KEY_FILE="./tsig.key"
CUSTOM_IP=""
CUSTOM_SUBDOMAIN=""

# Function to show help
show_help() {
    echo "Usage: $0 -i <your-ip> [-s <subdomain> -k <tsig-key-file>]"
    echo "Options:"
    echo "  -i, --ip         IP address to use for the sub-domain (required)"
    echo "  -s, --subdomain  Custom subdomain name (optional, random generated if not provided)"
    echo "  -k, --key        Path to TSIG key file (default to ./tsig.key)"
    echo "  -h, --help       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -i 192.168.1.100"
    echo "  $0 -i 192.168.1.100 -s myapp"
    echo "  $0 -i 192.168.1.100 -s myapp -k /path/to/tsig.key"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--key)
            if [ -z "$2" ]; then
                echo "Error: -k requires a value" >&2
                show_help
                exit 1
            fi
            TSIG_KEY_FILE="$2"
            shift 2
            ;;
        -i|--ip)
            if [ -z "$2" ]; then
                echo "Error: -i requires a value" >&2
                show_help
                exit 1
            fi
            CUSTOM_IP="$2"
            shift 2
            ;;
        -s|--subdomain)
            if [ -z "$2" ]; then
                echo "Error: -s requires a value" >&2
                show_help
                exit 1
            fi
            CUSTOM_SUBDOMAIN="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

if [ ! -f "$TSIG_KEY_FILE" ]; then
    echo "Error: TSIG key file '$TSIG_KEY_FILE' not found. Use -k to specify a custom path." >&2
    show_help
    exit 1
fi

# Ensure we have an ip address
if [ -z "$CUSTOM_IP" ]; then
    echo "Error: IP address is required." >&2
    show_help
    exit 1
fi

# Generate subdomain if not provided
if [ -z "$CUSTOM_SUBDOMAIN" ]; then
    CUSTOM_SUBDOMAIN="dev-$(openssl rand -hex 3)"
fi

# Function to add DNS record using nsupdate
add_dns_record() {
    local subdomain="$1"
    local ip="$2"
    
    nsupdate -k "$TSIG_KEY_FILE" <<EOF
server $KNOT_SERVER $KNOT_PORT
zone $ZONE
update add *.${subdomain}.${ZONE} 60 A $ip
send
quit
EOF
}

# Generates a yaml for distribution with the following content:
#   acme:
#     rootCa: |
#       -----BEGIN CERTIFICATE-----
#       ...
#       -----END CERTIFICATE-----
#     tsig:
#       keyName: "cm-key"
#       algorithm: "hmac-sha256"
#       secret: "..."
#   domain: "${CUSTOM_SUBDOMAIN}.${ZONE}"
generate_yaml() {
    local config_file="${CUSTOM_SUBDOMAIN}-config.yaml"
    
    # Extract TSIG key details from the key file
    local key_name=$(grep -o 'key "[^"]*"' "$TSIG_KEY_FILE" | sed 's/key "\([^"]*\)"/\1/')
    local key_secret=$(grep -o 'secret "[^"]*"' "$TSIG_KEY_FILE" | sed 's/secret "\([^"]*\)"/\1/')
    
    # Get root CA certificate
    local root_ca=""
    if curl -sk https://localhost:9000/roots.pem > /tmp/temp_root_ca.pem 2>/dev/null; then
        root_ca=$(cat /tmp/temp_root_ca.pem)
        rm -f /tmp/temp_root_ca.pem
    else
        echo "Warning: Could not retrieve root CA certificate from Step CA" >&2
        return 1
    fi
    
    # Generate YAML config file
    cat > "$config_file" <<EOF
acme:
  rootCa: |
$(echo "$root_ca" | sed 's/^/    /')
  tsig:
    keyName: "$key_name"
    algorithm: "hmac-sha256"
    secret: "$key_secret"
domain: "${CUSTOM_SUBDOMAIN}.${ZONE}"
EOF
    
    echo "📄 Generated developer config: $config_file"
}


echo "Checking zone configuration..."

# Perform zone transfer once and save to temp file
ZONE_FILE=$(mktemp)
dig @$KNOT_SERVER -p $KNOT_PORT -k "$TSIG_KEY_FILE" AXFR "$ZONE" > "$ZONE_FILE"

# Step 1: Check if requested subdomain already exists
EXISTING_RECORD=$(grep "^\*\.${CUSTOM_SUBDOMAIN}\.${ZONE}" "$ZONE_FILE")
if [ -n "$EXISTING_RECORD" ]; then
    EXISTING_IP=$(echo "$EXISTING_RECORD" | awk '{print $NF}')
    echo "Subdomain '${CUSTOM_SUBDOMAIN}' already exists with IP: ${EXISTING_IP}"
    echo "Wildcard record: *.${CUSTOM_SUBDOMAIN}.${ZONE} -> ${EXISTING_IP}"
    rm -f "$ZONE_FILE"
    exit 0
fi

# Step 2: Check if IP already has a subdomain
EXISTING_SUBDOMAIN=$(awk -v ip="$CUSTOM_IP" '
    /\*\..*[[:space:]]+A[[:space:]]+/ {
        if ($NF == ip) {
            print $1
            exit
        }
    }
' "$ZONE_FILE")

if [ -n "$EXISTING_SUBDOMAIN" ]; then
    # Extract the subdomain part (remove the *. prefix and zone suffix)
    DEV_SUBDOMAIN="${EXISTING_SUBDOMAIN#*.}"
    DEV_SUBDOMAIN="${DEV_SUBDOMAIN%.${ZONE}}"
    echo "IP ${CUSTOM_IP} already has subdomain: ${DEV_SUBDOMAIN}"
    echo "Existing wildcard: *.${DEV_SUBDOMAIN}.${ZONE} -> ${CUSTOM_IP}"
    rm -f "$ZONE_FILE"
    exit 0
fi

# Clean up temp file
rm -f "$ZONE_FILE"

# Step 3: Create new subdomain
echo "Creating new wildcard for ${CUSTOM_SUBDOMAIN}.${ZONE} -> ${CUSTOM_IP}"

if add_dns_record "$CUSTOM_SUBDOMAIN" "$CUSTOM_IP"; then
    echo "✅ Created new subdomain: ${CUSTOM_SUBDOMAIN}"
    echo "Your services are accessible at: *.${CUSTOM_SUBDOMAIN}.${ZONE}"
    echo "Anything with *.${CUSTOM_SUBDOMAIN}.${ZONE} will resolve to ${CUSTOM_IP}"
    echo "Test with: dig @${KNOT_SERVER} -p ${KNOT_PORT} app.${CUSTOM_SUBDOMAIN}.${ZONE}"
    
    # Generate developer configuration file
    generate_yaml
else
    echo "❌ Failed to create subdomain"
    exit 1
fi