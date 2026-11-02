# java-app-ops-lab

![CI](https://github.com/YazdanParsi/java-app-ops-lab/actions/workflows/ci.yml/badge.svg)

Hands-on lab for **operating an enterprise Java application**: a small Jakarta EE app on **WildFly**, run in **Docker**, deployed to **Kubernetes** with probes and resource limits, and to a **Linux VM with Ansible and systemd**. HTTPS is configured with a custom certificate through WildFly Elytron. The app contains deliberate faults (memory leak, thread deadlock) so incidents can be reproduced, diagnosed and documented as runbooks.

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
| `scripts/check-cert.sh` | TLS certificate expiry check; exit code 0/1/2/3 (OK/WARNING/CRITICAL/UNKNOWN) for Nagios/Zabbix-style monitoring |
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

**HTTPS with a custom certificate (WildFly Elytron)**
```bash
docker run -d --name tlslab -p 8443:8443 lab-app:1.0
docker exec tlslab keytool -genkeypair -alias lab -keyalg RSA -keysize 2048 -validity 365 \
  -dname "CN=localhost, O=Lab, C=CZ" -ext "SAN=dns:localhost,ip:127.0.0.1" \
  -keystore /opt/jboss/wildfly/standalone/configuration/lab.p12 -storetype PKCS12 -storepass changeit
docker exec -it tlslab /opt/jboss/wildfly/bin/jboss-cli.sh --connect    # Elytron commands: see runbooks/05
mkdir -p tls && docker exec tlslab keytool -exportcert -rfc -alias lab \
  -keystore /opt/jboss/wildfly/standalone/configuration/lab.p12 -storepass changeit > tls/lab.crt
curl --cacert tls/lab.crt https://localhost:8443/app/health          # OK – verified, no -k
scripts/check-cert.sh -H localhost -p 8443 -d 30                       # expiry monitoring
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
- [x] `runbooks/02-readiness-probe.md` – pod Running but not Ready: a bad readiness probe blocks the rollout
- [x] `runbooks/03-thread-deadlock.md` – app freezes, diagnosed with a thread dump
- [x] `runbooks/04-service-down-on-vm.md` – systemd service down on the VM
- [x] `runbooks/05-expired-certificate.md` – expired TLS certificate, renewed without downtime

## Progress

- [x] App runs on WildFly in Docker, configured with jboss-cli
- [x] Deployed to Kubernetes with probes, limits, ConfigMap and Secret
- [x] Health-check script passes ShellCheck
- [x] Deployed to a Linux VM with Ansible (idempotent second run)
- [x] HTTPS with a custom certificate (keytool, Elytron), expiry monitoring script
- [x] Incident runbooks written from real command output
