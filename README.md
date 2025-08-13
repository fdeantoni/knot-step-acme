# Knot DNS + Step CA ACME Development Environment

A Docker Compose setup that provides a local DNS server (Knot DNS) with ACME certificate authority (Step CA) for development and testing.

## Overview

This project sets up:

- **Knot DNS Server**: Authoritative DNS server for the `.test` domain
- **Step CA**: ACME-enabled certificate authority for issuing TLS certificates
- **Custom Network**: Isolated Docker network for service communication

## Architecture

```text
┌─────────────────┐    ┌─────────────────┐
│   Knot DNS      │    │    Step CA      │
│   10.0.0.10:53  │◄───┤  10.0.0.11:9000 │
│                 │    │                 │
│ • test. zone    │    │ • ACME endpoint │
│ • ca.test → CA  │    │ • ca.test cert  │
└─────────────────┘    └─────────────────┘
```

## Quick Start

1. **Start the services:**

   ```bash
   docker-compose up -d
   # or rebuild everything with:
   # docker compose up --build --force-recreate -d
   ```

2. **Wait for services to be healthy:**

   ```bash
   docker-compose ps
   ```

3. **Test DNS resolution:**

   ```bash
   dig @localhost -p 9053 ca.test A
   ```

4. **Access Step CA:**
   - ACME directory: `https://ca.test:9000/acme/acme/directory`
   - Root certificate: `https://ca.test:9000/roots.pem`

## Services

### Knot DNS (`knot`)

- **Port**: `9053` (mapped from container port 53)
- **IP**: `10.0.0.10` (internal network)
- **Zone file**: [`knot/test.zone`](knot/test.zone)
- **Config**: [`knot/knot.conf`](knot/knot.conf)

**DNS Records:**

- `ca.test.` → `10.0.0.11` (Step CA)
- `ns1.test.` → `10.0.0.10` (DNS server)

### Step CA (`step-ca`)

- **Port**: `9000`
- **IP**: `10.0.0.11` (internal network)
- **Domain**: `ca.test`
- **ACME Endpoint**: `/acme/acme/directory`

### Step Secrets (`step-secrets`)

- One-time service that generates CA password
- Creates `/home/step/secrets/password` with random password

## Configuration

### Default DNS Configuration

The Knot DNS server is configured in [`knot/knot.conf`](knot/knot.conf) with:

- Authority for `test.` domain
- HMAC-SHA256 key for dynamic updates automatically generated
- Forwarding to upstream DNS (1.1.1.1, 9.9.9.9) for other domains

### Default Step CA Configuration

- Automatically initialized on first run
- ACME provisioner enabled
- Certificate for `ca.test` domain
- Remote management enabled

### Enable Remote Access

By default everything runs on its own Docker network with DNS mapped to 0.0.0.0:9053 and step-ca mapped to 0.0.0.0:9000 so these are accessble on the hosts LAN IP. However, to make Knot DNS return the correct LAN IP address when queried for `ca.test`, you will need to reconfigure the test.zone file. You can do this as follows:

```bash
# First extract the tsig.key from Knot
./extract-tsig.sh

# Now switch to using the LAN IP for ca.test
./enable-remote.sh
```

### Configuring K3D

If you will run your K3D cluster on the same machine, you can tell it to use the knot and step-ca service:

```bash
k3d cluster create my-cluster \
  --k3s-arg "--cluster-dns=10.0.0.10@server:*" \
  --k3s-arg "--cluster-domain=cluster.local@server:*" \
  --network knot-step-acme_lab \
  --wait
```

If your K3D is running on another machine, you can instead tell K3D's CoreDNS to use your remote Knot instance instead. You can do so as follows:

```bash
# Create a config file pointing .test to your Knot instance
DNS_SERVER="<LAN IP exposing remote Knot>"
cat > coredns_custom.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  test.server: |
    test:53 {
        errors
        cache 30
        forward . $DNS_SERVER
    }
EOF

# Launch your K3D cluster with custom CoreDNS properties
k3d cluster create my-cluster \
  --volume ./coredns_custom.yaml:/var/lib/rancher/k3s/server/manifests/coredns-custom.yaml@server:0 \
  --wait
```

You can test if its working with the following:

```bash
# Deploy a test pod
kubectl run test-dns --image=alpine:latest --rm -it -- sh

# Inside the pod, test DNS resolution
nslookup ca.test
```


### Host Networking

By default, this setup uses Docker's bridge networking for isolation which is generally the recommended method. If really want, though, you can switch to host networking.

You can do so by setting `network_mode: host` in the docker-compose.yml file, e.g.:

```yaml
services:
    knot:
        # ...
        network_mode: host  # Use host networking

    step-ca:
        # ...
        network_mode: host  # Use host networking       
```

Replace the IP addresses in the `knot/test.zone` with the actual IPs in your network:

```zone
$ORIGIN test.
$TTL 60
@     IN SOA ns1.test. hostmaster.test. (1 1h 15m 30d 2h)
      IN NS  ns1.test.
ns1   IN A   192.168.1.10    ; LAN IP where this will run
@     IN A   192.168.1.100   ; Your development machine's LAN IP  
*     IN A   192.168.1.100   ; Your development machine's LAN IP  
ca    IN A   192.168.1.10    ; LAN IP where this will run
```

Before starting, ensure ports 9000 and 9053 are available:

```bash
# Check if port 9053 is in use
sudo netstat -tulpn | grep :9053
```

Lastly, create a resolved config that will forward any queries to the test domain to your knot instance:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/test-domain.conf << EOF
[Resolve]
DNS=127.0.0.1:9053~test
EOF
```

Now restart resolved:

```bash
sudo systemctl restart systemd-resolved
```

## Usage Examples

### Add a subdomain to Knot DNS

Use this to create a wildcard subdomain (*.your-sub.test) that points to your machine.

1) Extract the TSIG key and CA root
- Run [extract-tsig.sh](extract-tsig.sh). This writes [tsig.key](tsig.key) and [dev_root_ca.pem](dev_root_ca.pem).
  ```bash
  ./extract-tsig.sh
  ```

2) Trust the Step CA root on your host (so TLS to https://ca.test:9000 is trusted)
- macOS:
  ```bash
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain dev_root_ca.pem
  ```
- Debian/Ubuntu:
  ```bash
  sudo cp dev_root_ca.pem /usr/local/share/ca-certificates/dev_root_ca.crt
  sudo update-ca-certificates
  ```
- Windows (Administrator PowerShell):
  ```powershell
  certutil -addstore -f Root dev_root_ca.pem
  ```

3) Create the subdomain
- Run [add-subdomain.sh](add-subdomain.sh). You can provide your IP and desired subdomain, or let the script auto-detect/generate them.
  ```bash
  ./add-subdomain.sh -k ./tsig.key -i <your-ip> -s <subdomain>
  # Example:
  ./add-subdomain.sh -k ./tsig.key -s myapp
  ```
  This creates: *.myapp.test → <your-ip> in Knot.

4) Test
  ```bash
  dig @localhost -p 9053 app.<subdomain>.test A
  ```

### Using with curl/ACME clients

1. **Get the tsig.key and CA root certificate:**

   ```bash
   ./extract-tsig.sh
   ```

2. **Use with certbot:**

    ```bash
    docker run --rm -it \
        --network knot-step-acme_lab \
        --dns 10.0.0.10 \
        -v $(pwd)/dev_root_ca.pem:/etc/certs/dev_root_ca.pem \
        -e REQUESTS_CA_BUNDLE="/etc/certs/dev_root_ca.pem" \
        certbot/certbot certonly \
        --manual \
        --server https://ca.test:9000/acme/acme/directory \
        --preferred-challenges dns \
        --work-dir /tmp --logs-dir /tmp --config-dir /etc/letsencrypt \
        -d "example.test"
    ```

3. **Use nsupdate with TSIG key:**

    ```bash
    # Create nsupdate script
    cat > update.txt << EOF
    server localhost 9053
    zone test.
    update add _acme-challenge.example.test. 60 IN TXT "your-acme-challenge-token"
    send
    quit
    EOF

    # Apply the update
    nsupdate -k ./tsig.key update.txt

    # Clean up
    rm update.txt    
    ```

### DNS Testing

```bash
# Test DNS resolution
dig @localhost -p 9053 test SOA
dig @localhost -p 9053 ca.test A
dig @localhost -p 9053 anything.test A

# Test from container network
docker run --rm --network knot-step-acme_lab alpine:latest \
  nslookup ca.test 10.0.0.10
```

## Volumes

- `knot-db`: Persistent storage for Knot DNS zone files
- `step-data`: Persistent storage for Step CA configuration and certificates

## Network

- **Name**: `knot-step-acme_lab`
- **Subnet**: `10.0.0.0/24`
- **Gateway**: `10.0.0.1`

## Health Checks

Both services include health checks:

- **Knot**: Verifies DNS SOA response for `test.` domain
- **Step CA**: Verifies HTTPS endpoint accessibility

## Troubleshooting

### Check service logs

```bash
docker-compose logs knot
docker-compose logs step-ca
```

### Verify DNS resolution

```bash
# From host
dig @localhost -p 9053 ca.test A

# From container network
docker exec knot dig @127.0.0.1 ca.test A
```

### Test Step CA

```bash
# Check if CA is responding
curl -sk https://ca.test:9000/health

# Get CA roots
curl -sk https://ca.test:9000/roots.pem
```

### Reset everything

```bash
docker-compose down -v
docker-compose up -d
```

## File Structure

```text
.
├── docker-compose.yml          # Main orchestration
├── knot/
│   ├── Dockerfile             # Knot DNS container
│   ├── knot.conf              # Knot DNS configuration
│   └── test.zone              # DNS zone file
└── step-ca/
    ├── Dockerfile             # Step CA container
    └── start-step-ca.sh       # Step CA initialization script
```

## Requirements

- Docker
- Docker Compose
- (Optional) `dig` command for testing

## Notes

- The `.test` TLD is reserved for testing (RFC 6761)
- Change IP addresses in [`knot/test.zone`](knot/test.zone) if needed for your environment
- Step CA generates a random password on first run, stored in the `step-data` volume
- Services depend on each other: Step CA waits for Knot DNS to be healthy
