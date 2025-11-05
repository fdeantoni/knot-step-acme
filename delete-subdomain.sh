#!/bin/bash

ZONE="test."
KNOT_SERVER="127.0.0.1"
KNOT_PORT="9053"

# Initialize variables
TSIG_KEY_FILE="./tsig.key"
SUBDOMAIN=""

# Function to show help
show_help() {
    echo "Usage: $0 -s <subdomain> [-k <tsig-key-file>]"
    echo "Options:"
    echo "  -s, --subdomain  Subdomain name to delete (required)"
    echo "  -k, --key        Path to TSIG key file (default to ./tsig.key)"
    echo "  -h, --help       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -s myapp"
    echo "  $0 -s dev-abc123 -k /path/to/tsig.key"
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
        -s|--subdomain)
            if [ -z "$2" ]; then
                echo "Error: -s requires a value" >&2
                show_help
                exit 1
            fi
            SUBDOMAIN="$2"
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

# Ensure we have a subdomain
if [ -z "$SUBDOMAIN" ]; then
    echo "Error: Subdomain name is required." >&2
    show_help
    exit 1
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

echo "Checking zone configuration..."

# Perform zone transfer to verify subdomain exists
ZONE_FILE=$(mktemp)
dig @$KNOT_SERVER -p $KNOT_PORT -k "$TSIG_KEY_FILE" AXFR "$ZONE" > "$ZONE_FILE"

# Check if subdomain exists
EXISTING_RECORD=$(grep "^\*\.${SUBDOMAIN}\.${ZONE}" "$ZONE_FILE")
EXISTING_IP=$(echo "$EXISTING_RECORD" | awk '{print $NF}')

if [ -z "$EXISTING_RECORD" ]; then
    echo "❌ Subdomain '${SUBDOMAIN}' does not exist"
    rm -f "$ZONE_FILE"
    exit 1
fi

echo "Found subdomain: *.${SUBDOMAIN}.${ZONE} -> ${EXISTING_IP}"

# Clean up temp file
rm -f "$ZONE_FILE"

# Delete the subdomain
echo "Deleting subdomain '${SUBDOMAIN}'..."

if delete_dns_record "$SUBDOMAIN"; then
    echo "✅ Successfully deleted subdomain: ${SUBDOMAIN}"

    # Remove config file if it exists
    CONFIG_FILE="${SUBDOMAIN}-config.yaml"
    if [ -f "$CONFIG_FILE" ]; then
        rm -f "$CONFIG_FILE"
        echo "🗑️  Removed config file: $CONFIG_FILE"
    fi
else
    echo "❌ Failed to delete subdomain"
    exit 1
fi
