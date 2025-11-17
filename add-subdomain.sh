#!/bin/bash

ZONE="test."
KNOT_SERVER="127.0.0.1"
KNOT_PORT="9053"

# Initialize variables
TSIG_KEY_FILE="./tsig.key"
CUSTOM_IP=""
CUSTOM_SUBDOMAIN=""
FORCE=false

# Function to show help
show_help() {
    echo "Usage: $0 -i <your-ip> [-s <subdomain> -k <tsig-key-file> -f]"
    echo "Options:"
    echo "  -i, --ip         IP address to use for the sub-domain (required)"
    echo "  -s, --subdomain  Custom subdomain name (optional, random generated if not provided)"
    echo "  -k, --key        Path to TSIG key file (default to ./tsig.key)"
    echo "  -f, --force      Force overwrite existing subdomain with new IP"
    echo "  -h, --help       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -i 192.168.1.100"
    echo "  $0 -i 192.168.1.100 -s myapp"
    echo "  $0 -i 192.168.1.100 -s myapp -k /path/to/tsig.key"
    echo "  $0 -i 192.168.1.200 -s myapp -f  # Change myapp's IP to 192.168.1.200"
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
        -f|--force)
            FORCE=true
            shift
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

# Function to delete DNS record using nsupdate
delete_dns_record() {
    local subdomain="$1"

    nsupdate -k "$TSIG_KEY_FILE" <<EOF
server $KNOT_SERVER $KNOT_PORT
zone $ZONE
update delete *.${subdomain}.${ZONE} A
send
quit
EOF
}

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

    # Get CA certificate chain from dev_root_ca.pem (created by extract-tsig.sh)
    local root_ca=""
    if [ -f "dev_root_ca.pem" ]; then
        root_ca=$(cat dev_root_ca.pem)
    else
        echo "Warning: dev_root_ca.pem not found. Run ./extract-tsig.sh first." >&2
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

# Ensures config YAML file exists
ensure_config_exists() {
    local config_file="${CUSTOM_SUBDOMAIN}-config.yaml"
    if [ ! -f "$config_file" ]; then
        generate_yaml
    fi
}


echo "Checking zone configuration..."

# Perform zone transfer once and save to temp file
ZONE_FILE=$(mktemp)
dig @$KNOT_SERVER -p $KNOT_PORT -k "$TSIG_KEY_FILE" AXFR "$ZONE" > "$ZONE_FILE"

# Step 1: Check if requested subdomain already exists
EXISTING_RECORD=$(grep "^\*\.${CUSTOM_SUBDOMAIN}\.${ZONE}" "$ZONE_FILE")
EXISTING_IP=$(echo "$EXISTING_RECORD" | awk '{print $NF}')

if [ -n "$EXISTING_RECORD" ]; then
    # Subdomain exists - check if we need to update it
    if [ "$EXISTING_IP" = "$CUSTOM_IP" ]; then
        # Same IP, nothing to do
        echo "Subdomain '${CUSTOM_SUBDOMAIN}' already points to ${CUSTOM_IP}"
        ensure_config_exists
        rm -f "$ZONE_FILE"
        exit 0
    fi

    # Different IP
    if [ "$FORCE" = false ]; then
        # No force flag - exit with info
        echo "Subdomain '${CUSTOM_SUBDOMAIN}' already exists with IP: ${EXISTING_IP}"
        echo "Use --force to change it to ${CUSTOM_IP}"
        ensure_config_exists
        rm -f "$ZONE_FILE"
        exit 0
    fi

    # Force flag set - delete old record and continue
    echo "🔄 Updating subdomain '${CUSTOM_SUBDOMAIN}': ${EXISTING_IP} -> ${CUSTOM_IP}"
    if ! delete_dns_record "$CUSTOM_SUBDOMAIN"; then
        echo "❌ Failed to delete existing record"
        rm -f "$ZONE_FILE"
        exit 1
    fi
fi

# Step 2: Check if IP already has other subdomains and show info
EXISTING_SUBDOMAINS=$(awk -v ip="$CUSTOM_IP" '
    /\*\..*[[:space:]]+A[[:space:]]+/ {
        if ($NF == ip) {
            print $1
        }
    }
' "$ZONE_FILE")

if [ -n "$EXISTING_SUBDOMAINS" ]; then
    echo "ℹ️  IP ${CUSTOM_IP} also has the following subdomain(s):"
    while IFS= read -r subdomain_record; do
        # Extract the subdomain part (remove the *. prefix and zone suffix)
        DEV_SUBDOMAIN="${subdomain_record#*.}"
        DEV_SUBDOMAIN="${DEV_SUBDOMAIN%.${ZONE}}"
        echo "   - ${DEV_SUBDOMAIN}"
    done <<< "$EXISTING_SUBDOMAINS"
fi

# Clean up temp file
rm -f "$ZONE_FILE"

# Step 3: Create subdomain record
ACTION="Creating"
[ -n "$EXISTING_RECORD" ] && ACTION="Updating"

echo "${ACTION} wildcard *.${CUSTOM_SUBDOMAIN}.${ZONE} -> ${CUSTOM_IP}"

if add_dns_record "$CUSTOM_SUBDOMAIN" "$CUSTOM_IP"; then
    echo "✅ Success! Your services are accessible at: *.${CUSTOM_SUBDOMAIN}.${ZONE}"
    echo "Test with: dig @${KNOT_SERVER} -p ${KNOT_PORT} app.${CUSTOM_SUBDOMAIN}.${ZONE}"
    generate_yaml
else
    echo "❌ Failed to ${ACTION,,} subdomain"
    exit 1
fi