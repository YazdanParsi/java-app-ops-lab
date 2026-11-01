# java-app-ops-lab

![CI](https://github.com/YazdanParsi/java-app-ops-lab/actions/workflows/ci.yml/badge.svg)

Hands-on lab for **operating an enterprise Java application**: a small Jakarta EE app on **WildFly**, run in **Docker**, deployed to **Kubernetes** with probes and resource limits, and to a **Linux VM with Ansible and systemd**. The app contains deliberate faults (memory leak, thread deadlock) so incidents can be reproduced, diagnosed and documented as runbooks.

## Architecture

```
Java servlet app ─► WildFly (Docker image, configured with jboss-cli)
                    ├─► Kubernetes / minikube: Deployment, Service, ConfigMap, Secret, probes, limits
                    └─► Linux VM: Ansible ─► Podman + systemd unit ─► health-check script
```

## Repository layout

| Path | What it is |
|---|---|
| `app/` | Maven web app (`/health`, `/leak`, `/freeze`, `/work`), `config.cli` (WildFly config as code), multi-stage `Dockerfile` |
| `k8s/` | Namespace, ConfigMap (`JAVA_OPTS`), Secret, Deployment (readiness/liveness probes, requests/limits), Service |
| `scripts/healthcheck.sh` | Bash health check: HTTP, disk, memory; exit code 0/1 for monitoring |
| `ansible/` | Playbook that installs Podman, builds the image, installs a systemd unit and runs the health check (idempotent) |
| `runbooks/` | Incident runbooks: Symptom → Diagnosis → Root cause → Fix → Prevention |
| `.github/workflows/ci.yml` | CI: ShellCheck, Maven build, Docker build, Kubernetes manifest validation |

## How to run

**Docker**
```bash
docker build -t lab-app:1.0 app/
docker run --rm --name lab -p 8080:8080 lab-app:1.0
curl http://localhost:8080/app/health        # OK
```

**Kubernetes (minikube)**
```bash
minikube start --memory=4096 --cpus=2
minikube image build -t lab-app:1.0 app/
kubectl apply -f k8s/
kubectl -n lab get pods -w
kubectl -n lab port-forward svc/lab-app 8080:8080
```

**Linux VM with Ansible**
```bash
cd ansible
cp inventory.ini.example inventory.ini       # put the VM's IP in it
ansible all -m ping
ansible-playbook playbook.yml                # second run should show changed=0
```

## Endpoints

| URL | Purpose |
|---|---|
| `/app/health` | Health check used by probes and the script |
| `/app/leak` | Keeps 10 MB more memory alive on every call (OOMKilled scenario) |
| `/app/freeze` | Starts two threads that deadlock on two locks |
| `/app/work` | Needs one of those locks – hangs after `/freeze` (thread-dump scenario) |

## Runbooks

- [x] `runbooks/01-oomkilled.md` – container killed for exceeding its memory limit
- [ ] `runbooks/02-readiness-probe.md` – pod Running but not Ready, Service has no endpoints
- [ ] `runbooks/03-thread-deadlock.md` – app freezes, diagnosed with a thread dump
- [ ] `runbooks/04-service-down-on-vm.md` – systemd service down on the VM

## Progress

- [ ] App runs on WildFly in Docker, configured with jboss-cli
- [ ] Deployed to Kubernetes with probes, limits, ConfigMap and Secret
- [ ] Health-check script passes ShellCheck
- [ ] Deployed to a Linux VM with Ansible (idempotent second run)
- [ ] Incident runbooks written from real command output
