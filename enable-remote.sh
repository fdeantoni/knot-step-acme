#!/usr/bin/env bash
set -euo pipefail

TSIG_KEY_FILE="./tsig.key"

if [ ! -f "$TSIG_KEY_FILE" ]; then
    echo "Error: TSIG key file '$TSIG_KEY_FILE' not found. Run ./extract-tsig.sh first." >&2
    exit 1
fi

# Function to detect laptop IP across platforms
get_lan_ip() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux - try different methods
        hostname -I | awk '{print $1}' 2>/dev/null || \
        ip route get 1.1.1.1 | grep -oP 'src \K\S+' 2>/dev/null || \
        ip addr show | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' | cut -d/ -f1
    else
        echo "Unsupported OS" >&2
        exit 1
    fi
}

# Parse optional arguments. Accept -i|--ip to specify the LAN IP to use.
IP_ARG=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -i|--ip)
            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                IP_ARG="$2"
                shift 2
            else
                echo "Error: $1 requires an argument" >&2
                exit 1
            fi
            ;;
        -h|--help)
            echo "Usage: $0 [-i IP|--ip IP]" >&2
            exit 0
            ;;
        --) # end of options
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            # no more options
            break
            ;;
    esac
done

# Use provided IP if set, otherwise fall back to get_lan_ip()
LAN_IP="${IP_ARG:-$(get_lan_ip)}"

echo "Updating zone file to resolve ca.test and ns1.test to ${LAN_IP}..."

nsupdate -k ./tsig.key <<EOF
server 127.0.0.1 9053
zone test.
update delete ns1.test. A
update add ns1.test. 60 A ${LAN_IP}
update delete ca.test. A
update add ca.test. 60 A ${LAN_IP}
send
quit
EOF


