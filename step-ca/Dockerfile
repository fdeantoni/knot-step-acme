FROM smallstep/step-ca:latest

# We use curl for healthcheck
RUN apk add --no-cache curl || true

COPY --chmod=755 start-step-ca.sh /usr/local/bin/start-step-ca

EXPOSE 9000
ENTRYPOINT ["/usr/local/bin/start-step-ca"]
