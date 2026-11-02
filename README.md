# java-app-ops-lab

![CI](https://github.com/YazdanParsi/java-app-ops-lab/actions/workflows/ci.yml/badge.svg)

Hands-on lab for **operating an enterprise Java application**: a small Jakarta EE app on **WildFly**, run in **Docker**, deployed to **Kubernetes** with probes and resource limits, and to a **Linux VM with Ansible and systemd**. HTTPS is configured with a custom certificate through WildFly Elytron, the Kubernetes deployment is managed with **GitOps (Argo CD)**, and the same manifests were deployed to **Azure Kubernetes Service (AKS)**. The app contains deliberate faults (memory leak, thread deadlock) so incidents can be reproduced, diagnosed and documented as runbooks.

## Architecture

```
Java servlet app ─► WildFly (Docker image, configured with jboss-cli)
                    ├─► Kubernetes / minikube: Deployment, Service, ConfigMap, Secret, probes, limits
                    │     └─ deployed by Argo CD from k8s/ in this repo (auto-sync, prune, self-heal)
                    ├─► Azure: ACR (amd64 image) ─► AKS (managed identity AcrPull) ─► Standard Load Balancer
                    └─► Linux VM: Ansible ─► Podman + systemd unit ─► health-check script
```

## Repository layout

| Path | What it is |
|---|---|
| `app/` | Maven web app (`/health`, `/leak`, `/freeze`, `/work`), `config.cli` (WildFly config as code), multi-stage `Dockerfile` |
| `k8s/` | Namespace, ConfigMap (`JAVA_OPTS`), Secret, Deployment (readiness/liveness probes, requests/limits), Service |
| `azure/deploy-aks.sh`, `azure/cleanup.sh` | Scripted Azure deployment: resource group, ACR, amd64 image, AKS, public LoadBalancer, health check – and full cleanup |
| `argocd/lab-app.yaml` | Argo CD `Application`: deploys `k8s/` from `main` with automated sync, prune and self-heal |
| `scripts/healthcheck.sh` | Bash health check: HTTP, disk, memory; exit code 0/1 for monitoring |
| `scripts/check-cert.sh` | TLS certificate expiry check; exit code 0/1/2/3 (OK/WARNING/CRITICAL/UNKNOWN) for Nagios/Zabbix-style monitoring |
| `ansible/` | Playbook that installs Podman, builds the image, installs a systemd unit and runs the health check (idempotent) |
| `runbooks/` | Incident runbooks: Symptom → Diagnosis → Root cause → Fix → Prevention |
| `.github/workflows/ci.yml` | CI: ShellCheck (`scripts/`, `azure/`), Maven build, Docker build, Kubernetes manifest validation |

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

**Azure Kubernetes Service (AKS)**
```bash
az login
LOC=denmarkeast azure/deploy-aks.sh                    # RG, ACR, amd64 image, AKS, LoadBalancer, health check
azure/cleanup.sh                                       # deletes the resource group and the kubeconfig entries
```
Verified run (2026-11-02, Azure for Students):

| Step | Result |
|---|---|
| Registry | `javalab27625.azurecr.io`, admin user disabled – pushes with `az acr login` (Entra ID token) |
| Image | built with `docker buildx --platform linux/amd64` on an ARM Mac, `linux/amd64`, 495 MB |
| Cluster | AKS 1.36.4, free tier, 1 × `Standard_B2s_v2` node (Ubuntu 24.04, containerd), Azure CNI Overlay |
| Image pull | `Successfully pulled image "javalab27625.azurecr.io/lab-app:1.0" in 15.693s` – kubelet managed identity with **AcrPull**, no `imagePullSecrets` |
| Exposure | Service patched to `LoadBalancer` → public IP from the Azure Standard Load Balancer, `curl http://<ip>:8080/app/health` → `OK` |
| Node resource group | VM Scale Set, VNet, NSG (port 8080 rule added by Kubernetes), Load Balancer, 2 public IPs, kubelet managed identity |

Constraints hit on the way, and how they were solved:

| Problem | Diagnosis | Fix |
|---|---|---|
| Region rejected | Azure Policy *Allowed resource deployment regions* (`az policy assignment list`) | used an allowed region |
| `Standard_B2s` not allowed in Germany West Central | AKS create error listed the orderable sizes | checked other allowed regions with `az vm list-skus` (restrictions = 0) |
| Node pool stuck at `0/1 nodes` | Activity Log of the `MC_*` group: *exceeding approved StandardDlsv7Family Cores quota … Current Limit: 0* | `az vm list-usage` → Denmark East has Bsv2 quota → `Standard_B2s_v2` |
| `az acr build` → `TasksOperationsNotAllowed` | ACR Tasks are disabled on student subscriptions | build locally with `docker buildx --platform linux/amd64 --push` |
| `Fatal glibc error: CPU does not support x86-64-v3` during the cross-build | the UBI 10 based WildFly image needs x86-64-v3, which Rosetta emulation lacks | Maven and jboss-cli stages run on `$BUILDPLATFORM`; the target stage only `COPY`s – nothing is emulated |

**GitOps with Argo CD**
```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd port-forward svc/argocd-server 8090:443     # UI: https://localhost:8090
argocd login localhost:8090 --username admin --insecure
kubectl apply -f argocd/lab-app.yaml                          # Argo CD now deploys k8s/ from GitHub
argocd app get lab-app                                        # Synced to main (<commit>), Healthy
```
Verified behaviour:
- **Deploy by commit** – changing `replicas` in `k8s/deployment.yaml` and pushing created a new history entry and a second pod; no `kubectl` against the cluster.
- **Self-heal** – `kubectl scale --replicas=3` was reverted to Git's value within seconds (`Synced -> OutOfSync -> partial sync -> Synced`).
- **Rollback** – `git revert` + push rolled the cluster back; `argocd app history` shows every deployed commit.

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
- [x] GitOps with Argo CD: automated sync, self-heal and rollback via `git revert`
- [x] Deployed to Azure AKS with ACR, managed identity and a public LoadBalancer (scripted, cleaned up)
- [x] Incident runbooks written from real command output
