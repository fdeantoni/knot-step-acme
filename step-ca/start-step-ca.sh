#!/usr/bin/env sh
set -eu

STEP_HOME="/home/step"
PW="$STEP_HOME/secrets/password"

# Wait for the password file created by step-secrets
echo "Waiting for Step CA password..."
for i in $(seq 1 60); do
  [ -s "$PW" ] && break
  sleep 1
done
[ -s "$PW" ] || { echo "Password file not found at $PW"; exit 1; }
chmod 600 "$PW"

# Initialize CA on first run (idempotent)
if [ ! -f "$STEP_HOME/config/ca.json" ]; then
  echo "Initializing Step CA config..."
  step ca init \
    --password-file "$PW" \
    --acme --deployment-type=standalone \
    --remote-management \
    --name="Dev CA" \
    --dns="ca.test" \
    --provisioner="dev" \
    --address=":9000"
fi

# Launch Step CA
exec step-ca --password-file "$PW" "$STEP_HOME/config/ca.json"
