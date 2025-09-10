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

5. **Extract TSIG and create subdomain**

   ```bash
    # First extract the tsig.key file and root certificate
    ./extract-tsig.sh
    # Optional: enable remote access to Step and Knot
    ./enable-remote.sh
    # Create a wildcard subdomain *.mydomain.test entry
    ./add-subdomain.sh -s mydomain -i <ip it should resolve to>
    ```

   You should now have a `mydomain-config.yaml` file with all the details to configure an ACME client that should interact with Knot, and Knot will now resolve any query for *.mydomain.test to the IP number you specified.

6. **Test it out**

    ```bash
    dig @localhost -p 9053 +short ca.test A
    dig @localhost -p 9053 +short apples.mydomain.test A
    ```

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

By default everything runs on its own Docker network with DNS mapped to 0.0.0.0:9053 and step-ca mapped to 0.0.0.0:9000 so these are accessble on the hosts LAN IP. However, to make Knot DNS return the correct LAN IP address when queried for `ca.test`, you will need to reconfigure the test.zone file to use the LAN IP for `ca.test`. You can do this as follows:

```bash
# First extract the tsig.key from Knot
./extract-tsig.sh

# Now switch to using the LAN IP for ca.test
./enable-remote.sh

# Check if it worked correctly
dig @localhost -p 9053 +short ca.test A
```

The last command tests if Knot returns the right IP address when resolving `ca.test`. By default the `enable-remote.sh` script will try to detect your LAN IP and use that. If this detection fails, you can also provide the IP address that it should use for `ca.test`:

```bash
./enable-remote.sh --ip 192.168.1.10
```

This will then ensure that dns name `ca.test` will resolve to 192.168.1.10 

### Add a subdomain to Knot DNS

Use this to create a wildcard subdomain (*.your-sub.test) that points to your machine.

1) Extract the TSIG key and CA root

    Run [extract-tsig.sh](extract-tsig.sh). This writes [tsig.key](tsig.key) and [dev_root_ca.pem](dev_root_ca.pem).

    ```bash
    ./extract-tsig.sh
    ```

2) Create the subdomain

    Run [add-subdomain.sh](add-subdomain.sh). You can provide your IP and desired subdomain, or let the script auto-detect/generate them, e.g.:

    ```bash
    ./add-subdomain.sh -i 192.168.1.50 -s myapp
    ```

    This creates: *.myapp.test → 192.168.1.50 in Knot and generates a `myapp-config.yaml` file containing:

    - Step CA root certificate
    - TSIG key configuration for DNS updates
    - Sub-domain that was configured


3) Test

    ```bash
    dig @localhost -p 9053 app.<subdomain>.test A
    ```

### Configure your desktop resolver for .test

Point your workstation's DNS lookups for the .test domain to the Knot instance so host apps resolve ca.test and your subdomains.

Decide the Knot address you’ll use:

- If running locally via Docker: 127.0.0.1:9053
- If using a remote host: <LAN-IP-of-host>:9053

Next, configure your resolver to use your knot-step-acme instance to resolve anything for the `*.test` domain:

**OSX**:

```bash
sudo mkdir -p /etc/resolver
sudo tee /etc/resolver/test >/dev/null <<EOF
nameserver 127.0.0.1
port 9053
EOF
# If Knot is remote, replace 127.0.0.1 with its LAN IP
# Optional: flush DNS cache
sudo killall -HUP mDNSResponder || true
```

**Linux with systemd-resolved**:

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/test.conf >/dev/null <<EOF
[Resolve]
DNS=127.0.0.1:9053
Domains=~test
EOF
sudo systemctl restart systemd-resolved
# If Knot is remote, use DNS=<LAN-IP>:9053 instead
```

For details about `resolved.conf` see the [man page](https://manpages.debian.org/bookworm/systemd-resolved/resolved.conf.5.en.html).


**DNSMasq**:

If you like to use [dnsmasq](https://dnsmasq.org/doc.html), add the following entry to your dnsmasq.conf file:

```conf
# Knot Step Acme Server
server=/test/127.0.0.1#9053
# If Knot is remote, replace 127.0.0.1 with the <LAN-IP> of Knot instead
```

It is also recommended to use DNSMasq if you cannot get your per-domain resolver to work correctly. In such a case configure DNSMasq as above, and add upstream servers pointing your actual dns servers:

```conf
server=1.1.1.1
server=1.0.0.1
server=9.9.9.9
no-resolv # Tells dnsmasq not use /etc/resolv.conf for upstream
```

DNSMasq will now send everything for *.test to the knot-step-acme instance, and everything else to the upstream dns servers you specified. Restart dnsmasq and configure your system resolver (e.g. `/etc/resolv.conf`) to use it instead. 

**If all else Fails**:

If the per-domain resolvers do not seem to work and using dnsmasq is not an option for you, as a last resort you can configure knot-step-acme `docker-compose.yaml` to also port-map your hosts port 53 to the container's port 9053. Assuming knot-step-acme is running on a machine with LAN IP 192.168.1.10, you can expose Knot DNS on port 53 as follows:

```yaml
services:
  # ...
  knot:
    # ...
    ports:
      - "0.0.0.0:9053:53/tcp"
      - "0.0.0.0:9053:53/udp"
      - "192.168.1.10:53:53/tcp"
      - "192.168.1.10:53:53/udp"      
    # ...
```

Restart knot-step-acme:

```bash
docker compose restart
```

Now configure your machine to use knot-step-acme as your dns server, i.e. 192.168.1.10. Note that knot-step-acme is configured to use Cloudflare DNS (1.1.1.1) and Quad9 (9.9.9.9) as upstream, so any query it gets that is not for *.test will be forwarded to those upstream dns servers instead.

**Verify**:

```bash
dig +short ca.test A # check if our Step CA can be resolved
dig +short www.joindns4.eu # check if upstream is working
```

### Using K3D with knot-step-acme

If you will run your K3D cluster on the same machine, you can tell it to use the same docker network as knot-step-acme:

```bash
k3d cluster create my-cluster \
  --k3s-arg "--cluster-dns=10.0.0.10@server:*" \
  --k3s-arg "--cluster-domain=cluster.local@server:*" \
  --network knot-step-acme_lab \
  --wait
```

Anything running on K3D will now use the Knot Step Acme instance running on the docker network. If, however, your K3D is *not* running on the same docker network, you will need to configure K3D's CoreDNS instead. We will have to tell it to use your remote Knot instance on port 9053 to resolve anything with `*.test`, which you can do so as follows:

```bash
# Create a config file pointing .test to your Knot instance (non-standard DNS port 9053)
DNS_SERVER="<LAN IP exposing remote Knot>:9053"
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

Most likely you will also want to use `cert-manager` to issue ACME certificates. If you do, take note that the default configuration has Knot exposed on port 9053. This means cert manager will need to be instructed *not* to use `/etc/resolv.conf` from the node. You can do so as follows when installing cert-manager via helm:

```bash
DNS_SERVER="<LAN IP exposing remote Knot>:9053"
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set installCRDs=true \
  --set 'extraArgs={--dns01-recursive-nameservers-only,--dns01-recursive-nameservers=$DNS_SERVER}'
```

See [Setting Nameservers for DNS01 Self Check](https://cert-manager.io/docs/configuration/acme/dns01/#setting-nameservers-for-dns01-self-check) for details about this.

Alternatively, you can also add a mapping for Knot to listen on port 53 on your local LAN IP by editing the `docker-compose.yml` 

```yaml
services:
  # ...
  knot:
    # ...
    ports:
      - "0.0.0.0:9053:53/tcp"
      - "0.0.0.0:9053:53/udp"
      - "192.168.1.10:53:53/tcp"
      - "192.168.1.10:53:53/udp"      
    # ...
```

### If you really, really, want to use Host Networking

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
# Check if ports 9000 and 9053 are in use
sudo netstat -tulpn | egrep ':(9000|9053)\b'
```

If ports are available, you can go ahead and start up knot-step-acme:

```bash
docker compose up --build --force-recreate -d
```


## Usage Examples

### Using with curl/ACME clients

1) Get the tsig.key and CA root certificate:

   ```bash
   ./extract-tsig.sh
   ```

2) Trust the Step CA root on your host (so TLS to [https://ca.test:9000] is trusted)

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

3. Use with certbot:

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

4. Use nsupdate with TSIG key:

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
