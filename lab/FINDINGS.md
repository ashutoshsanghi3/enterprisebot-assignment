# Findings — Part 4 debug lab

Fill in one entry per defect you find. Paste the *actual* output you saw —
we cross-check it against your session recording and your git diff, and the
diagnostic path matters more to us than the fix itself.

Before you start investigating, begin recording:
`script -q part4-session.log` (or `asciinema rec part4-session.cast`), and
commit that file alongside this one.

---

## Defect 1

**Symptom** (what you observed — paste the real command output):
```text
==> installing the broken chart
Release "debug-lab" does not exist. Installing it now.
Error: server-side apply failed for object debug-lab/migrate batch/v1, Kind=Job: Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
```

**Cause** (the actual root cause, not the symptom restated):
The `migrate` Job specification in the Helm chart omitted the mandatory Kubernetes Job pod template field `spec.template.spec.restartPolicy`. Kubernetes API validation rejects any Job resource where `restartPolicy` is unspecified because the default Pod restart policy (`Always`) is illegal for batch Jobs.

**Fix** (what you changed, and why this over alternatives):
Added `restartPolicy: Never` to `broken-chart/templates/migrate-job.yaml` under `spec.template.spec`. `Never` was selected over `OnFailure` so a failed database migration terminates cleanly rather than restarting repeatedly within the same pod container without operator intervention.

**How I found it** (the sequence of commands/reasoning that led you here):
Ran `./scenario.sh up` to install the lab release. Helm's server-side apply failed immediately with the API server admission controller validation error.

---

## Defect 2

**Symptom:**
```text
krishna@Krishna lab % kubectl get pods -n debug-lab
NAME                        READY   STATUS                       RESTARTS   AGE
backend-7948fd6b4b-lm4s4    0/1     CreateContainerConfigError   0          4m20s
gateway-5cbdcd4bf8-8zdlp    0/1     CreateContainerConfigError   0          4m20s
metrics-547dccf75-9mpjj     0/1     CreateContainerConfigError   0          4m20s
migrate-nhkcc               0/1     CreateContainerConfigError   0          43s
reporter-6f8bff6b8d-zfp2d   0/1     CreateContainerConfigError   0          4m20s
worker-5fcd6b9b6b-z9x6b     0/1     CreateContainerConfigError   0          4m20s
```

Inspected using `kubectl describe pod backend-7948fd6b4b-lm4s4 -n debug-lab`:
```text
Events:
  Type     Reason     Age                   From               Message
  ----     ------     ----                  ----               -------
  Normal   Scheduled  6m25s                 default-scheduler  Successfully assigned debug-lab/backend-7948fd6b4b-lm4s4 to demo-control-plane
  Normal   Pulling    6m25s                 kubelet            spec.containers{backend}: Pulling image "docker.io/ebinterview/eb-debug-app:1.0.1"
  Normal   Pulled     6m20s                 kubelet            spec.containers{backend}: Successfully pulled image "docker.io/ebinterview/eb-debug-app:1.0.1" in 4.154s (4.154s including waiting). Image size: 3279587 bytes.
  Normal   Pulled     84s (x24 over 6m20s)  kubelet            spec.containers{backend}: Container image "docker.io/ebinterview/eb-debug-app:1.0.1" already present on machine and can be accessed by the pod
  Warning  Failed     71s (x26 over 6m20s)  kubelet            spec.containers{backend}: Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root (pod: "backend-7948fd6b4b-lm4s4_debug-lab(e14122cc-fd4e-4e26-9bd8-4e8a9cffc335)", container: backend)
```

**Cause:**
Workloads configured `runAsNonRoot: true` in their `securityContext`, but the container image specifies the runtime user by string name (`nonroot`) rather than a numeric UID. The Kubelet cannot resolve username-to-UID mappings without inspecting `/etc/passwd` inside the image at runtime, so admission blocks container creation if a numeric UID is not explicitly supplied.

**Fix:**
Set an explicit numeric user ID via `runAsUser: 1000` alongside `runAsNonRoot: true` across the workload templates in `broken-chart/templates/`.

**How I found it:**
Ran `kubectl get pods -n debug-lab`, observed every workload blocked in `CreateContainerConfigError`, and ran `kubectl describe pod backend-7948fd6b4b-lm4s4 -n debug-lab` to read the Kubelet error event.

---

## Defect 3

**Symptom:**
```text
krishna@Krishna lab % kubectl get pods -n debug-lab
NAME                        READY   STATUS                       RESTARTS   AGE
backend-757868cb4-nlhvl     0/1     Running                      0          2m9s

krishna@Krishna lab % kubectl logs backend-757868cb4-nlhvl -n debug-lab
2026/11/06 13:15:00 eb-debug-app 2.0.0 starting: mode=api pod=backend-757868cb4-nlhvl listening on :8081 (image default is 8081; set PORT to override)

krishna@Krishna lab % ./scenario.sh verify
...
   FAIL  backend does not answer on http://backend:8080/healthz
```

**Cause:**
The application binary listens on port `8081` by default unless overridden, whereas the container port definitions, Kubernetes Service, and HTTP readiness probes were targeting port `8080`. Because no server process was bound to `8080`, probe requests failed and kept the pod at `0/1 Ready`.

**Fix:**
Injected the environment variable `PORT: "8080"` into the container environment specification across the Helm chart values and templates so the application runtime socket binds to `8080`, matching the probes and Service target port.

**How I found it:**
Checked container logs with `kubectl logs backend-757868cb4-nlhvl -n debug-lab`. The startup banner logged `listening on :8081 (image default is 8081; set PORT to override)`. Correlated this with the readiness probe definition in `kubectl describe pod`, which was probing port `8080`.

---

## Defect 4

**Symptom:**
```text
krishna@Krishna lab % kubectl get pods -n debug-lab
NAME                        READY   STATUS                       RESTARTS      AGE
worker-56c89c4d9d-tlf6r     0/1     CrashLoopBackOff             2 (15s ago)   29s

krishna@Krishna lab % kubectl logs worker-56c89c4d9d-tlf6r -n debug-lab
2026/11/06 13:27:20 FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

**Cause:**
The worker container enforces `readOnlyRootFilesystem: true` in its `securityContext`. On startup, the binary attempts to create a cache directory at `/var/cache/app`, which fails with an OS read-only filesystem error (`EROFS`) and causes the container process to crash immediately.

**Fix:**
Mounted a writable `emptyDir: {}` volume at `/var/cache/app` in `broken-chart/templates/worker.yaml` under `volumeMounts` and `volumes`. This satisfied the application's write requirement while preserving container root filesystem immutability.

**How I found it:**
Observed the worker pod entering `CrashLoopBackOff` via `kubectl get pods -n debug-lab`, then retrieved container standard error output using `kubectl logs worker-56c89c4d9d-tlf6r -n debug-lab`.

---

## Defect 5

**Symptom:**
```text
krishna@Krishna lab % kubectl logs gateway-74fdfcb458-2vjwv -n debug-lab
2026/11/06 13:26:00 eb-debug-app 2.0.0 starting: mode=gateway pod=gateway-74fdfcb458-2vjwv listening on :8080 (image default is 8081; set PORT to override)
2026/11/06 13:26:06 readiness failed: backend not reachable: GET http://backend.default.svc:8080/healthz: Get "http://backend.default.svc:8080/healthz": dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host
2026/11/06 13:26:06 GET /healthz -> 503 (from 10.244.0.1:37020)
```

**Cause:**
The gateway application was configured to query the backend service at `http://backend.default.svc:8080/healthz`. Because the lab workloads are deployed into the `debug-lab` namespace, CoreDNS returned `NXDOMAIN` for the `default.svc` domain suffix.

**Fix:**
Updated the backend target URL configuration in `broken-chart/values.yaml` (or gateway template) to use the local service name `http://backend:8080` (or `http://backend.debug-lab.svc.cluster.local:8080`), allowing CoreDNS to resolve the service within `debug-lab`.

**How I found it:**
Inspected failing readiness probe logs via `kubectl logs gateway-74fdfcb458-2vjwv -n debug-lab`, which reported DNS resolution failures for `backend.default.svc`.

---

## Defect 6

**Symptom:**
```text
krishna@Krishna lab % kubectl logs reporter-c6584d9dd-rwgzr -n debug-lab
2026/11/06 13:26:00 eb-debug-app 2.0.0 starting: mode=reporter pod=reporter-c6584d9dd-rwgzr listening on :8080 (image default is 8081; set PORT to override)
2026/11/06 13:26:06 pod list failed: kubernetes API returned HTTP 403: {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"pods is forbidden: User \"system:serviceaccount:debug-lab:reporter\" cannot list resource \"pods\" in API group \"\" in the namespace \"debug-lab\"","reason":"Forbidden","details":{"kind":"pods"},"code":403}
2026/11/06 13:26:06 GET /healthz -> 503 (from 10.244.0.1:55274)
```

**Cause:**
The RBAC configuration for the reporter ServiceAccount had two distinct defects:
1. Malformed YAML list formatting in the `Role` definition where the list item indicator had detached keys (`- \n apiGroups: [""]`), preventing Helm and the API server from applying valid rule blocks.
2. The `RoleBinding` omitted `namespace: {{ .Release.Namespace }}` under the ServiceAccount subject block, defaulting the subject binding to the `default` namespace instead of `debug-lab`.

**Fix:**
Corrected the YAML indentation and explicitly set `namespace: {{ .Release.Namespace }}` under both `metadata` and the ServiceAccount subject block in `RoleBinding` within `broken-chart/templates/reporter.yaml`.

**How I found it:**
Observed HTTP 403 Forbidden errors in `kubectl logs reporter-c6584d9dd-rwgzr -n debug-lab`. Inspected RBAC objects with `kubectl get role,rolebinding -n debug-lab` and reviewed `reporter.yaml` to find the missing subject namespace and indentation defects.

---

If you ran out of time on any defect, say so here and describe what you would
have tried next — that section is read carefully and counts in your favour.

### Time-Constrained Investigation Note: Reporter Healthz Parsing Crash

**Current State:**
All core platform workloads (`backend`, `gateway`, `worker`, `metrics`, `migrate`) pass verification, and RBAC verification confirms the service account can list pods (`ServiceAccount debug-lab/reporter can list pods: PASS`). However, the reporter deployment remains `0/1 Ready` with `./scenario.sh verify` reporting 9 passing and 2 failing checks:

```text
krishna@Krishna lab % ./scenario.sh verify
==> verifying goal state in namespace debug-lab
   PASS  migrate Job completed
   PASS  deployment backend: 1/1 ready
   PASS  deployment gateway: 1/1 ready
   PASS  deployment worker: 1/1 ready
   FAIL  deployment reporter: 0/1 ready
   PASS  deployment metrics: 1/1 ready
   PASS  no pods in CrashLoopBackOff
   PASS  ServiceAccount debug-lab/reporter can list pods
   PASS  backend answers on http://backend:8080/healthz
   PASS  gateway /status reports backend=ok
   FAIL  reporter /report does not return a pod count

 2 check(s) failing, 9 passing. Keep digging — every failure is a symptom.
```

Pod logs show repeated JSON unmarshaling errors during probe checks:
```text
2026/11/06 14:44:37 pod list failed: parse pod list: unexpected end of JSON input
2026/11/06 14:44:37 GET /healthz -> 503 (from 10.244.0.1:35494)
```

**What Was Attempted:**
1. **RBAC Scoping:** Verified and expanded permissions in the namespaced `Role`, `RoleBinding`, `ClusterRole`, and `ClusterRoleBinding` across core API resources (`pods`, `services`, `endpoints`). The verification harness confirms `ServiceAccount debug-lab/reporter can list pods: PASS`.
2. **Downward API Environment:** Verified `PORT: "8080"` and `NAMESPACE: debug-lab` are properly populated in the container via `kubectl get deployment reporter -n debug-lab -o jsonpath='{.spec.template.spec.containers[0].env}'`.
3. **Filesystem Buffer:** Mounted an `emptyDir: {}` volume at `/tmp` in `reporter.yaml` to ensure any temporary unmarshaling buffers under `readOnlyRootFilesystem: true` do not fail on disk writes.

**What I Would Try Next:**
1. Attach an ephemeral debugging container using `kubectl debug -it <reporter-pod> -n debug-lab --image=curlimages/curl` to query `https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT/api/v1/namespaces/debug-lab/pods` directly with the mounted token (`/var/run/secrets/kubernetes.io/serviceaccount/token`), inspecting raw HTTP response headers, content length, and payload body.
2. Verify if the Go binary client library expects alternative downward API environment variables (such as `POD_NAME` or `POD_NAMESPACE`) to build its in-cluster client configuration.
3. Check whether the client-side unmarshaler fails when the pod list contains pods without status IPs during startup, testing an `initialDelaySeconds` increase on the readiness probe or adding an `initContainer` barrier until all peer pods reach `Running`.
