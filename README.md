# java-app-ops-lab

A hands-on lab for **operating a Java application** the way production teams do: WildFly on Linux and Kubernetes/OpenShift, automated with Ansible, and broken on purpose to practise incident diagnosis.

> Status: work in progress (started October 2026).

I administer a production Jenkins platform (a Java application) on Red Hat OpenShift and RHEL. This lab extends that experience to Java application servers and documents every failure scenario as a runbook.

## Planned contents

- [ ] `app/` – sample Java web app (`.war`) deployed to **WildFly** in a container
- [ ] WildFly configuration with `jboss-cli`: logging, datasource, JVM options
- [ ] `k8s/` – Deployment, Service, Route/Ingress, ConfigMap, Secret, readiness/liveness probes, resource limits (OpenShift Local or minikube)
- [ ] `ansible/` – playbook that prepares a Linux host and deploys the app
- [ ] `scripts/healthcheck.sh` – Bash health check (HTTP endpoint, disk, memory) with proper exit codes
- [ ] `runbooks/` – break-and-fix scenarios:
  - [ ] Pod OOMKilled (memory limit vs JVM heap)
  - [ ] Failing readiness probe
  - [ ] Application freeze – thread dump analysis (`jcmd`, `jstack`)

## Tech stack

Java · WildFly · Kubernetes / OpenShift · Linux · Ansible · Bash · Docker

## Runbook format

Every incident in `runbooks/` follows the same structure: **Symptom → Diagnosis → Root cause → Fix → Prevention** (see `runbooks/TEMPLATE.md`).

## Author

Hossein Khezripour Gharaee – [LinkedIn](https://www.linkedin.com/in/hossein-khezri-) · [build-doctor](https://github.com/YazdanParsi/build-doctor)
