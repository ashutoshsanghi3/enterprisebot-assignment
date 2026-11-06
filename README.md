# DevOps / Platform Engineer Take-Home Assignment

## How to Run and Verify

### Prerequisites
- Docker & Docker Desktop
- `kind`
- `kubectl`
- `helm`

### 1. One-Command Setup (Parts 1–3)
Run the automated bootstrap script to provision the local kind cluster, install `ingress-nginx`, build and load the application image, and deploy the Helm chart:
```bash
chmod +x setup.sh
./setup.sh
```

### 2. Verify Service Endpoints
Test connectivity through the ingress controller:
```bash
# Check workload status
kubectl get pods -n demo
kubectl get ingress -n demo

# Root endpoint
curl -H "Host: demo.local" http://localhost/

# Health endpoint
curl -i -H "Host: demo.local" http://localhost/healthz
```

### 3. Verify Lab Environment (Part 4)
Run the scenario scripts inside `lab/`:
```bash
cd lab
./scenario.sh up
./scenario.sh verify
```

---

## Resource Requests and Limits Rationale

Configured container resources in `chart/values.yaml`:

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

- **Requests (`50m` CPU, `64Mi` Memory):** The service is a lightweight Python HTTP application. Under idle and typical ping loads, the process consumes ~30–45 MiB resident memory and minimal baseline CPU. Allocating `50m` CPU and `64Mi` memory guarantees stable scheduling headroom on nodes without reserving unused host resources.
- **Limits (`200m` CPU, `128Mi` Memory):** Setting CPU limits to `200m` allows bursting during container startup and brief traffic spikes without starving adjacent cluster workloads. The hard `128Mi` ceiling stops potential memory leak runaways and triggers deterministic OOMKills before threatening node stability.

---

## What I Deliberately Skipped (and the Risks)

1. **Part 4: Deep-Patching Reporter JSON Parsing (`/healthz` 503)**
   - **What was skipped:** After resolving 5 core defects (migration Job restart policy, numeric non-root UID enforcement, container port configuration, worker scratch cache volume, and gateway DNS resolution) and fixing reporter RBAC permissions, the reporter container remained at `0/1 Ready` due to an internal `parse pod list: unexpected end of JSON input` failure. I halted further modification to respect the 3-hour time constraint.
   - **Risk:** The reporter pod fails its readiness probe, leaving 2 failing checks in `./scenario.sh verify` (`deployment reporter: 0/1 ready` and `reporter /report does not return a pod count`).
   - **What I would do next:** Run `kubectl debug` with an interactive curl container to query `https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT/api/v1/namespaces/debug-lab/pods` directly using the reporter's token to inspect raw API response headers and JSON length, verifying whether the binary's client library requires downward API environment bindings or encounters chunked transfer truncation.

2. **Cert-Manager & Automated TLS:**
   - **What was skipped:** Left TLS termination disabled on `demo.local` to prevent local certificate trust errors on the grading harness.
   - **Risk:** All traffic passes over unencrypted HTTP.

3. **Horizontal Pod Autoscaling (HPA) & PodDisruptionBudgets (PDB):**
   - **What was skipped:** Deployed a static replica count of 2 without dynamic scaling rules or disruption budgets.
   - **Risk:** Inability to handle sudden load surges automatically, and potential downtime if node maintenance evicts both replicas concurrently.

---

## Production Readiness Improvements

If deploying this setup to production (e.g., AWS EKS):
1. **Security & Identity:**
   - Migrate from static ServiceAccount tokens to IAM Roles for Service Accounts (IRSA) / EKS Pod Identity.
   - Implement `NetworkPolicy` objects to restrict pod-to-pod network paths.
   - Integrate Trivy / Grype into CI/CD pipelines to block container images with HIGH or CRITICAL CVEs.
2. **Reliability & Availability:**
   - Add a `PodDisruptionBudget` (`minAvailable: 1`) and configure `topologySpreadConstraints` across multiple Availability Zones.
   - Configure a Horizontal Pod Autoscaler (HPA) using `metrics-server` for automated traffic scaling.
3. **Observability:**
   - Standardize JSON application logging and forward logs via fluent-bit.
   - Expose Prometheus `/metrics` endpoints and configure alerting rules for latency, 5xx rates, and failing probes.

---

## How I used AI

In accordance with the assignment's AI policy, AI assistants were used selectively during the exercise for the following tasks:

- **Part 1 (Service & Docker):** Used Gemini to generate the initial Flask app boilerplate and the basic multi-stage Dockerfile structure. I manually stepped in to configure the virtual environment `PATH` routing and enforced the non-root `appuser` ownership, as the AI initially defaulted to a standard root execution.
- **Part 2 (Helm Chart):** Prompted Gemini to scaffold the base Kubernetes YAMLs (Deployment, Service, Ingress) to save time typing API versions. I manually wired up the `ConfigMap` injections, adjusted the health probe timings, and added `ingressClassName: nginx` to the Ingress resource, which the AI missed but is required for the local kind controller to pick up the routes.
- **Part 3 (Automation):** Used Gemini to fetch the exact `kubectl wait` label selectors for the `ingress-nginx` controller. Local `kind` clusters often fail Helm deployments if the admission webhook isn't fully ready, so using AI saved me from digging through Kubernetes docs for the exact command. I manually wrote the Bash idempotency logic (checking `kind get clusters` before creation) to ensure the script safely handles multiple executions.
- **Part 4 — Reporter Deployment & RBAC Troubleshooting:** Used an AI assistant to evaluate Kubernetes RBAC role bindings, investigate the initial `403 Forbidden` API responses, and analyze the subsequent `unexpected end of JSON input` failure on the reporter's `/healthz` probe.
- **ServiceAccount Manifest Creation:** Used an AI assistant to assist with drafting standard boilerplate YAML for the reporter's `ServiceAccount`, `Role`, and `RoleBinding` definitions.
- **What I had to correct:** 
  * The assistant repeatedly recommended applying broader `ClusterRole` permissions across multiple resource groups (`apps`, `extensions`), which masked standard namespaced scoping best practices. I rejected these suggestions and kept the permissions strictly scoped to namespaced resources in `debug-lab`.
  * The assistant proposed replacing the HTTP `/healthz` probe with a `tcpSocket` check to bypass the crash, which I rejected because it fails the scenario's verification requirement of a valid HTTP status code.
  * The assistant proposed mounting an `emptyDir` at `/tmp` to resolve the JSON parsing crash; when testing proved this did not clear the issue in the binary, I stopped further speculation to respect the 3-hour lab time limit and documented the findings honestly.