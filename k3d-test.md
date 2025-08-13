# K3D Test of ACME Issuer

First create the cluster:

```bash
#!/bin/bash
mkdir $PWD/k3d-storage
k3d cluster create test \
  --api-port 6550 --servers 1 --agents 1 \
  --k3s-arg "--disable=traefik@server:0" \
  --k3s-arg "--cluster-dns=10.0.0.10@server:*" \
  --k3s-arg "--cluster-domain=cluster.local@server:*" \
  --network knot-step-acme_lab \
  --port "80:80@loadbalancer" --port "443:443@loadbalancer" \
  --volume $PWD/k3d-storage:/var/lib/rancher/k3s/storage@all \
  --wait

helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.watchIngressWithoutClass=true \
  --set controller.ingressClassResource.default=true \
  --wait
```

Install cert-manager:

```bash
helm install \
  cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.18.2 \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

Get the root cert:

```bash
mkdir -p certs
curl -sk https://localhost:9000/roots.pem > certs/step-ca-root.pem
```

Create the secrets:

```bash
kubectl create secret generic step-ca-root \
  --from-file=ca.crt=certs/step-ca-root.pem \
  -n cert-manager

kubectl create secret generic knot-tsig-secret \
  --from-literal=secret="tt9LsPQcj2Gv298XEWpu6adBzhzG56AWYU7uJexqemQ=" \
  -n cert-manager
```

Get the base64 encoded value of the step-ca root cert:

```bash
ROOT_CERT=$(base64 -i certs/step-ca-root.pem)
echo $ROOT_CERT
```

Create the issuer

```bash
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: step-ca-acme
spec:
  acme:
    # Your Step CA ACME server endpoint
    server: https://ca.test:9000/acme/acme/directory

    # Email for ACME registration (required by Step CA)
    email: admin@dev.test

    # Secret to store the ACME account private key
    privateKeySecretRef:
      name: step-ca-acme-account-key

    # Use the Step CA root certificate for validation
    caBundle: ${ROOT_CERT}
    # DNS-01 challenge solver using your Knot DNS with TSIG
    solvers:
    - dns01:
        rfc2136:
          nameserver: "10.0.0.10:53"
          tsigKeyName: "cm-key"
          tsigAlgorithm: "HMACSHA256"
          tsigSecretSecretRef:
            name: knot-tsig-secret
            key: secret
```

Create an echo service with an ingress:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-service
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: echo-service
  template:
    metadata:
      labels:
        app: echo-service
    spec:
      containers:
      - name: echo
        image: ealen/echo-server:latest
        ports:
        - containerPort: 80
        env:
        - name: PORT
          value: "80"
        - name: LOGS__IGNORE__PING
          value: "true"
        resources:
          requests:
            memory: "32Mi"
            cpu: "10m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        livenessProbe:
          httpGet:
            path: /ping
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /ping
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: echo-service
  namespace: default
spec:
  selector:
    app: echo-service
  ports:
  - name: http
    port: 80
    targetPort: 80
    protocol: TCP
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo-ingress
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: "step-ca-acme"
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  tls:
  - hosts:
    - echo.test
    - api.test
    secretName: echo-tls-secret
  rules:
  - host: echo.test
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: echo-service
            port:
              number: 80
  - host: api.test
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: echo-service
            port:
              number: 80
```

Test it out:

```bash
curl -k https://echo.test/
```
