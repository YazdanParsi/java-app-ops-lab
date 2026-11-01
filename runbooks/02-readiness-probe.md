# Runbook 02 – Pod Running but not Ready (failed readiness probe)

| | |
|---|---|
| **Severity** | Medium – the release is blocked; users are not affected while the old pod serves |
| **Where** | Kubernetes (minikube), namespace `lab`, deployment `lab-app` |
| **Reproduced** | 2026-11-01, by deploying a release whose readiness probe path has a typo (`/app/ready` instead of `/app/health`) |

## Symptom

- The deployment pipeline (or `rollout status`) never finishes:

```text
$ kubectl -n lab rollout status deploy/lab-app --timeout=90s
Waiting for deployment "lab-app" rollout to finish: 1 old replicas are pending termination...
error: timed out waiting for the condition
```

- The new pod is `Running` but `0/1` Ready, with **no restarts**:

```text
$ kubectl -n lab get pods -o wide
NAME                       READY   STATUS    RESTARTS      AGE   IP
lab-app-5bf7c7c544-bwdxf   0/1     Running   0             99s   10.244.0.5   <- new release
lab-app-f54bdbbb7-h9x4b    1/1     Running   1 (17m ago)   18m   10.244.0.4   <- old release
```

## Diagnosis

**1. Which pods receive traffic?**

```text
$ kubectl -n lab get endpoints lab-app
NAME      ENDPOINTS
lab-app   10.244.0.4:8080

$ kubectl -n lab get endpointslices -l kubernetes.io/service-name=lab-app \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
10.244.0.4 ready=true
10.244.0.5 ready=false
```

Only the old pod is in the Service. The new pod is known but excluded because it is not Ready.

**2. Why is the new pod not Ready?**

```text
$ kubectl -n lab get events --sort-by=.lastTimestamp | grep -i readiness | tail -3
Warning   Unhealthy   pod/lab-app-5bf7c7c544-bwdxf   Readiness probe failed: HTTP probe failed with statuscode: 404
```

404 means the application answers, but the probe asks for a URL that does not exist.

**3. What does the live deployment ask for?**

```text
$ kubectl -n lab get deploy lab-app -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}'
/app/ready
```

**4. Are users affected?** Call the Service from inside the cluster, like another app would:

```text
$ kubectl -n lab run curl --rm -i --restart=Never --image=curlimages/curl -- -s http://lab-app:8080/app/health
OK
```

```text
$ kubectl -n lab get rs
NAME                 DESIRED   CURRENT   READY
lab-app-5bf7c7c544   1         1         0      <- new ReplicaSet, never Ready
lab-app-f54bdbbb7    1         1         1      <- old ReplicaSet, still serving
```

## Root cause

The new release changed the readiness probe path to `/app/ready`, which the application does not serve. The probe gets HTTP 404, so the pod never becomes Ready.

The rolling update only removes the old pod after the new one is Ready, so the rollout stops halfway: the old version keeps serving and the new version never receives traffic. Kubernetes does **not** roll back on its own – after `progressDeadlineSeconds` (default 600 s) it only marks the deployment `ProgressDeadlineExceeded`.

A failing **readiness** probe never restarts a pod (`RESTARTS 0`); it only removes the pod from the Service. A failing **liveness** probe would restart it.

## Fix

Roll back to the previous revision:

```text
$ kubectl -n lab rollout history deploy/lab-app
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
3         <none>

$ kubectl -n lab rollout undo deploy/lab-app
deployment.apps/lab-app rolled back

$ kubectl -n lab rollout status deploy/lab-app
deployment "lab-app" successfully rolled out
```

The rollback reused the old ReplicaSet, so no new pod had to start – the broken pod was simply terminated:

```text
$ kubectl -n lab get pods
NAME                       READY   STATUS        RESTARTS
lab-app-5bf7c7c544-bwdxf   0/1     Terminating   0
lab-app-f54bdbbb7-h9x4b    1/1     Running       1 (18m ago)
```

## Verification

```text
$ kubectl -n lab get deploy lab-app -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}'
/app/health
```

One pod, `1/1` Ready, Service endpoint unchanged – no user-facing downtime during the whole incident.

## Prevention

- In the deployment pipeline, run `kubectl rollout status --timeout=…` and call `kubectl rollout undo` automatically if it fails.
- Keep manifests in Git and deploy from Git (GitOps, e.g. Argo CD) instead of live `kubectl patch`, so every change is reviewed and reversible.
- Record why each revision exists: `kubectl annotate deploy/lab-app kubernetes.io/change-cause="…"` – `CHANGE-CAUSE <none>` makes history hard to read.
- Test probe paths in a staging environment before production; schema validation (kubeconform) cannot catch a wrong URL.
- Alert when a deployment reports `ProgressDeadlineExceeded`.
