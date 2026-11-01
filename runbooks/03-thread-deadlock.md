# Runbook 03 – Application freezes: thread deadlock (thread dump)

| | |
|---|---|
| **Severity** | High – business requests hang while the health check is still green |
| **Where** | Kubernetes (minikube), namespace `lab`, deployment `lab-app` |
| **Reproduced** | 2026-11-01, by calling `/app/freeze` (two threads take two locks in opposite order) |

## Symptom

- Business requests hang and time out on the client side:

```text
$ curl -s --max-time 5 localhost:8081/app/work; echo "exit=$?"
exit=28                      # 28 = curl timeout
```

- At the same time the health check is green and Kubernetes sees nothing wrong:

```text
$ curl -s --max-time 5 localhost:8081/app/health; echo "exit=$?"
OK
exit=0
$ kubectl -n lab get pods
NAME                      READY   STATUS    RESTARTS      AGE
lab-app-f54bdbbb7-h9x4b   1/1     Running   1 (24m ago)   25m
```

## Diagnosis – thread dump

**1. Find the Java process inside the container**

```text
$ kubectl -n lab exec deploy/lab-app -- jcmd
192 jdk.jcmd/sun.tools.jcmd.JCmd                       <- jcmd itself
60 /opt/jboss/wildfly/jboss-modules.jar ...            <- WildFly
```

**2. Take the dump** (in practice: 2–3 dumps about 10 s apart – threads stuck in the same place in every dump are really stuck, not just slow)

```bash
kubectl -n lab exec deploy/lab-app -- jcmd 60 Thread.print > threaddump-1.txt
```

Full dump: [`evidence/03-threaddump.txt`](evidence/03-threaddump.txt) (697 lines).

**3. The JVM detects the deadlock itself**

```text
$ grep -A 12 "Found one Java-level deadlock" threaddump-1.txt
Found one Java-level deadlock:
=============================
"default task-2":
  waiting to lock monitor 0x0000aaaad9cad7f0 (object 0x00000000e8f3e8b8, a java.lang.Object),
  which is held by "lab-deadlock-1"

"lab-deadlock-1":
  waiting to lock monitor 0x0000aaaad94078c0 (object 0x00000000e8f3e8c8, a java.lang.Object),
  which is held by "lab-deadlock-2"

"lab-deadlock-2":
  waiting to lock monitor 0x0000aaaad9cad7f0 (object 0x00000000e8f3e8b8, a java.lang.Object),
  which is held by "lab-deadlock-1"
```

`…e8b8` is `LOCK_A`, `…e8c8` is `LOCK_B`. `lab-deadlock-1` and `lab-deadlock-2` wait for each other – a cycle that can never resolve. `default task-2` (a WildFly/Undertow worker thread serving `/work`) is queued behind it.

**4. Exact code locations**

```text
"lab-deadlock-1" ... elapsed=102.51s ... waiting for monitor entry
   java.lang.Thread.State: BLOCKED (on object monitor)
	at lab.FreezeServlet.lockBoth(FreezeServlet.java:27)
	- waiting to lock <0x00000000e8f3e8c8>      <- wants LOCK_B
	- locked <0x00000000e8f3e8b8>               <- holds LOCK_A
	at lab.FreezeServlet.lambda$doGet$0(FreezeServlet.java:17)

"default task-2" ... waiting for monitor entry
   java.lang.Thread.State: BLOCKED (on object monitor)
	at lab.WorkServlet.doGet(WorkServlet.java:15)
	- waiting to lock <0x00000000e8f3e8b8>      <- wants LOCK_A
```

## Escalation – the worker pool runs out

The client gives up after a few seconds, but **the server thread stays blocked forever**. Every `/work` call permanently consumes one worker thread:

```text
$ for i in $(seq 1 40); do curl -s --max-time 3 localhost:8081/app/work > /dev/null & done; wait
$ kubectl -n lab exec deploy/lab-app -- jcmd 60 Thread.print | grep -A1 '^"default task' | grep -c BLOCKED
16                                    <- the whole worker pool (16 threads with a 1-CPU limit)
$ curl -s --max-time 5 localhost:8081/app/health; echo "exit=$?"
exit=28                               <- now even /health cannot be served
```

Kubernetes finally reacts – readiness first (pod removed from the Service), then liveness (container restarted):

```text
$ kubectl -n lab get pods -w
lab-app-f54bdbbb7-h9x4b   1/1     Running   1 (28m ago)   29m
lab-app-f54bdbbb7-h9x4b   0/1     Running   1 (28m ago)   29m
lab-app-f54bdbbb7-h9x4b   0/1     Running   2 (1s ago)    29m

$ kubectl -n lab get events --sort-by=.lastTimestamp | grep -iE "liveness|readiness|killing"
Warning   Unhealthy   Liveness probe failed: Get "http://10.244.0.4:8080/app/health": context deadline exceeded
Normal    Killing     Container wildfly failed liveness probe, will be restarted
Warning   Unhealthy   Readiness probe failed: Get "http://10.244.0.4:8080/app/health": context deadline exceeded
```

```text
$ kubectl -n lab describe pod -l app=lab-app | grep -A6 "Last State"
    Last State:     Terminated
      Reason:       Completed
      Exit Code:    0
```

Note: `Completed / Exit Code 0` looks harmless. The kubelet sent SIGTERM and WildFly shut down cleanly – only the **events** show the restart was caused by a failed liveness probe. Events expire after about an hour, so capture them early.

## Root cause

`FreezeServlet` starts two threads that take the same two locks in **opposite order** (A→B and B→A, `FreezeServlet.java:17–18`). Each holds one lock and waits for the other forever. Any request that needs `LOCK_A` (`WorkServlet.java:15`) blocks behind them, and each such request pins a worker thread until the pool is exhausted.

The health check does not touch these locks, so it stayed green until the pool ran out – the incident was invisible to Kubernetes for several minutes.

## Fix

- **Mitigation:** restart the pod (here the liveness probe did it automatically; manually: `kubectl -n lab rollout restart deploy/lab-app`). A restart clears the stuck threads but does not fix the bug – calling `/freeze` again reproduces it.
- **Code fix:** always acquire locks in the same global order (A, then B) everywhere, or use `ReentrantLock.tryLock(timeout)` so a thread gives up instead of waiting forever.

## Verification

After the restart, business requests work again:

```text
$ curl -s --max-time 5 localhost:8081/app/work; echo "exit=$?"
Work done
exit=0
```

## Prevention

- Take 2–3 thread dumps ~10 s apart **before** restarting – a restart destroys the evidence.
- Alert on request latency and timeouts, not only on the health endpoint; a green `/health` does not mean the app works.
- Make the liveness check detect deadlocks: `ManagementFactory.getThreadMXBean().findDeadlockedThreads()` returns the stuck threads, so `/health` can fail as soon as a deadlock exists.
- Set timeouts on locks and on outgoing calls, so one stuck dependency cannot exhaust the worker pool.
- Keep JDK diagnostic tools (`jcmd`) in the runtime image, or know the fallback `kill -3 <pid>` (SIGQUIT prints a thread dump to the log without stopping the JVM).
