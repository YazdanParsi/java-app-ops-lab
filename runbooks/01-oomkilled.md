# Runbook 01 – Container OOMKilled (exit code 137)

| | |
|---|---|
| **Severity** | High – the pod restarts and in-flight requests fail |
| **Where** | Kubernetes (minikube), namespace `lab`, deployment `lab-app` |
| **Reproduced** | 2026-11-01, by calling `/app/leak` (keeps +10 MB per call) |

## Symptom

- Client requests suddenly fail with an empty response or `connection refused`.
- `kubectl get pods` shows the pod `0/1 Running` with `RESTARTS` increased.
- The application log simply **stops** – no error, no shutdown message.

```text
$ kubectl -n lab get pods
NAME                       READY   STATUS    RESTARTS     AGE
lab-app-554f9dcc87-cw7zg   0/1     Running   1 (8s ago)   54m
```

## Diagnosis

**1. Why did the last container stop?**

```text
$ kubectl -n lab describe pod -l app=lab-app | grep -A6 "Last State"
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Sun, 01 Nov 2026 14:50:22 +0100
      Finished:     Sun, 01 Nov 2026 15:44:35 +0100
```

`137 = 128 + 9` → the process received SIGKILL. `OOMKilled` → the kernel killed it for exceeding the container memory limit.

**2. What did the application log before it died?** (`--previous` = the killed container)

```text
$ kubectl -n lab logs deploy/lab-app --previous | tail -3
14:44:32,573 WARN  [org.infinispan.CONFIG] ISPN000977: Low memory detected. Memory usage has exceeded the configured threshold.
14:44:32,578 WARN  [org.infinispan.CONFIG] ISPN000977: Low memory detected. ...
```

No `OutOfMemoryError` – the JVM never reached its own heap limit. The only early warning was Infinispan's low-memory message, 3 seconds before the kill. (Container logs are in UTC, the cluster in CET.)

**3. Kernel confirmation**

```text
$ minikube ssh -- "sudo dmesg | grep -i -m3 'killed process'"
Memory cgroup out of memory: Killed process 5015 (java) total-vm:2447600kB, anon-rss:780320kB, ... oom_score_adj:872
```

- `Memory cgroup out of memory` → the **container** limit was hit, not the node's RAM.
- `anon-rss:780320kB` ≈ 762 MiB → right at the 768 Mi limit.
- `oom_score_adj:872` → the pod is Burstable QoS (requests < limits).

**Timeline:** 15:44:32 low-memory warning → 15:44:35 kernel kills `java` → 15:44:36 port-forward `connection refused` → kubelet restarts the container.

## Root cause

The heap was sized at `-XX:MaxRAMPercentage=75.0` of a 768 Mi limit ≈ 576 Mi. WildFly also needs memory **outside** the heap (metaspace, thread stacks, JIT code cache, direct buffers). Heap + non-heap passed 768 Mi after ~440 MB had leaked, so the kernel killed the process before Java could react.

Two problems combined: a memory leak in the code (`LeakServlet`), and a heap setting that leaves too little headroom for non-heap memory.

## Fix

Lower the heap share and let the JVM exit cleanly when the heap is full:

```yaml
# k8s/configmap.yaml
JAVA_OPTS: "-XX:MaxRAMPercentage=50.0 -XX:+ExitOnOutOfMemoryError"
```

```bash
kubectl --context minikube apply -f k8s/configmap.yaml
kubectl --context minikube -n lab rollout restart deploy/lab-app   # env vars are read only at start
kubectl --context minikube -n lab rollout status deploy/lab-app
kubectl --context minikube -n lab exec deploy/lab-app -- printenv JAVA_OPTS
```

## Verification

The same leak test now fails **inside Java**, with a clear message, before the container limit:

```text
$ kubectl -n lab describe pod -l app=lab-app | grep -A6 "Last State"
    Last State:     Terminated
      Reason:       Error
      Exit Code:    3
$ kubectl -n lab logs deploy/lab-app --previous | grep -i -B2 "Terminating due to"
14:51:36,865 WARN  [org.infinispan.CONFIG] ISPN000977: Low memory detected. ...
Terminating due to java.lang.OutOfMemoryError: Java heap space
```

| | Before | After |
|---|---|---|
| Heap max | ~576 Mi (75 %) | ~384 Mi (50 %) |
| Leaked before failure | 440 MB | 310 MB |
| Who stopped the process | Linux kernel (SIGKILL) | the JVM itself |
| Exit code / reason | 137 / OOMKilled | 3 / Error |
| Cause visible in the app log | no | yes |

Kubernetes restarted the pod automatically in both cases; the difference is that the cause is now obvious from the log.

## Prevention

- Fix the leak in code – a restart only frees the memory until it fills up again.
- Keep heap at ~50–60 % of the limit for WildFly in small containers; raise the limit rather than the percentage.
- Alert on pod restarts, on `OOMKilled` / exit code 137, and on the `ISPN000977` log line.
- Next improvement: `-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp` to capture what filled the heap.
- For critical workloads, set requests = limits (Guaranteed QoS) so the pod is the last to be killed under node pressure.
