# Runbook 04 – Service down on the Linux VM (systemd + Ansible)

| | |
|---|---|
| **Severity** | High – the application is unreachable |
| **Where** | Ubuntu 22.04 VM `labvm`, systemd unit `lab-app.service` running a Podman container `lab` |
| **Reproduced** | 2026-11-01: **A)** container crash (`podman kill`), **B)** service stopped and disabled by an operator |

## Symptom

The health check fails and nothing listens on port 8080:

```text
$ ssh labvm@orb /usr/local/bin/healthcheck.sh; echo "exit=$?"
FAIL  http   http://localhost:8080/app/health -> curl: (7) Failed to connect to localhost port 8080 after 0 ms: Connection refused
OK    disk   / 29% used (limit 90%)
OK    memory 12% used (limit 90%)
exit=1
```

Exit code `1` is what monitoring reacts to. Memory dropping from ~23 % to ~12 % shows the JVM is gone.

## A) Container crash – systemd repairs it

```text
$ ssh labvm@orb 'sudo podman kill lab; sleep 1; /usr/local/bin/healthcheck.sh; echo "exit=$?"; sleep 15; /usr/local/bin/healthcheck.sh; echo "exit=$?"'
FAIL  http   http://localhost:8080/app/health -> curl: (7) ... Connection refused
exit=1
OK    http   http://localhost:8080/app/health -> OK
exit=0
```

The journal shows systemd restarting the service exactly `RestartSec=5` seconds after the crash:

```text
$ ssh labvm@orb "sudo journalctl -u lab-app --since '15 min ago' --no-pager | grep 'systemd\['"
16:28:40 systemd[1]: lab-app.service: Main process exited, code=exited, status=137/n/a
16:28:40 systemd[1]: lab-app.service: Failed with result 'exit-code'.
16:28:45 systemd[1]: lab-app.service: Scheduled restart job, restart counter is at 1.
16:28:45 systemd[1]: Started Lab Java app on WildFly (Podman container).

$ ssh labvm@orb systemctl show lab-app -p NRestarts
NRestarts=2
```

`status=137` = 128 + 9 (SIGKILL). Downtime per crash ≈ 8 s (5 s restart delay + ~2.5 s WildFly boot). **No action needed** – but a rising `NRestarts` must be investigated, because systemd hides repeated crashes.

`journalctl -n 60` is not enough here: WildFly writes ~100 boot lines after each restart and pushes the systemd lines out. Use `--since` instead.

## B) Service stopped and disabled – systemd does not repair it

`Restart=always` only restarts after a crash. A deliberate stop is respected:

```text
$ ssh labvm@orb "systemctl is-active lab-app; systemctl is-enabled lab-app"
inactive
disabled

$ ssh labvm@orb "sudo ss -tlnp | grep 8080 || echo 'nothing listens on 8080'"
nothing listens on 8080
```

`disabled` matters as much as `inactive`: the service would also stay down after the next reboot.

**Who did it?** `sudo` logs every command to the journal:

```text
$ ssh labvm@orb "sudo journalctl _COMM=sudo --since '10 min ago' --no-pager | grep COMMAND"
16:28:40 sudo[9295]:  khehos : PWD=/home/khehos ; USER=root ; COMMAND=/usr/bin/podman kill lab
16:32:59 sudo[10383]: khehos : PWD=/home/khehos ; USER=root ; COMMAND=/usr/bin/systemctl disable --now lab-app
```

## Root cause

- **A)** The container process died (simulated with SIGKILL). systemd restarted it automatically.
- **B)** An operator ran `systemctl disable --now lab-app` – the VM drifted from its intended configuration (enabled + running).

## Fix

Re-apply the desired state with Ansible instead of repairing the VM by hand:

```text
$ cd ansible && ansible-playbook playbook.yml
TASK [Enable and start the service] ****
changed: [labvm]
TASK [Wait until WildFly answers] ****
FAILED - RETRYING: [labvm]: Wait until WildFly answers (29 retries left).
ok: [labvm]
TASK [Show the health-check result] ****
    "OK    http   http://localhost:8080/app/health -> OK",
PLAY RECAP ****
labvm : ok=10   changed=1    unreachable=0    failed=0    skipped=1
```

`changed=1` – Ansible changed exactly the one thing that had drifted. The single retry is WildFly still booting.

## Verification

```text
$ ssh labvm@orb "systemctl is-active lab-app; systemctl is-enabled lab-app"
active
enabled
```

## Prevention

- Run the playbook regularly (or from CI) so drift is corrected automatically; a normal run reports `changed=0`.
- Alert on `healthcheck.sh` exit code ≠ 0 and on increasing `NRestarts`.
- Make changes through the playbook and Git, not with ad-hoc `sudo` commands; the sudo journal is the audit trail when that rule is broken.
- Use `StartLimitBurst` / `StartLimitIntervalSec` so a crash loop ends in a visible `failed` state instead of restarting forever.
