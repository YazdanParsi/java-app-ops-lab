# Runbook 05 – Expired TLS certificate on WildFly

| | |
|---|---|
| **Severity** | High – every client that verifies certificates is cut off; the server itself reports nothing |
| **Where** | WildFly 42 (container `tlslab`), HTTPS listener on port 8443, Elytron key store `labKS` (`lab.p12`) |
| **Reproduced** | 2026-11-02, by replacing the server certificate with one that expired the day before |

## Background – how TLS is wired in WildFly

```
lab.p12 (PKCS12 keystore: private key + certificate)
  └─► Elytron key-store   labKS
        └─► key-manager   labKM
              └─► server-ssl-context labSSC (TLSv1.3, TLSv1.2)
                    └─► Undertow https-listener "https" (port 8443)
```

Set up with `keytool` and jboss-cli:

```bash
keytool -genkeypair -alias lab -keyalg RSA -keysize 2048 -validity 365 \
  -dname "CN=localhost, O=Lab, C=CZ" -ext "SAN=dns:localhost,ip:127.0.0.1" \
  -keystore $JBOSS_HOME/standalone/configuration/lab.p12 -storetype PKCS12 -storepass changeit
```

```text
/subsystem=elytron/key-store=labKS:add(path=lab.p12, relative-to=jboss.server.config.dir, credential-reference={clear-text=changeit}, type=PKCS12)
/subsystem=elytron/key-manager=labKM:add(key-store=labKS, credential-reference={clear-text=changeit})
/subsystem=elytron/server-ssl-context=labSSC:add(key-manager=labKM, protocols=["TLSv1.3","TLSv1.2"])
/subsystem=undertow/server=default-server/https-listener=https:write-attribute(name=ssl-context, value=labSSC)
reload
```

Before this, WildFly served its auto-generated default certificate: self-signed (`subject = issuer = CN=localhost`) and valid for 10 years – fine for a test, never for production.

## Symptom

Clients that verify the certificate fail; with `-S` curl shows the real reason:

```text
$ curl -sS --cacert tls/lab.crt https://localhost:8443/app/health; echo "exit=$?"
curl: (60) SSL certificate problem: certificate has expired
exit=60
```

Exit code 60 is the same as for an untrusted certificate – only the message tells them apart. The WildFly log shows **no error**: the server keeps serving the expired certificate.

## Diagnosis

**1. OpenSSL's verdict** (with the trusted CA, so only the expiry can fail):

```text
$ openssl s_client -connect localhost:8443 -servername localhost -CAfile tls/lab.crt </dev/null 2>/dev/null | grep "Verify return code"
    Verify return code: 10 (certificate has expired)
```

Useful codes: `10` expired · `18`/`19` self-signed · `20`/`21` missing CA or intermediate · `62` host name mismatch.

**2. The validity dates of the certificate the server actually presents:**

```text
$ openssl s_client -connect localhost:8443 -servername localhost </dev/null 2>/dev/null | openssl x509 -noout -dates
notBefore=Oct 31 13:24:17 2026 GMT
notAfter=Nov  1 13:24:17 2026 GMT          <- yesterday
```

**3. The check monitoring would use:**

```text
$ openssl s_client -connect localhost:8443 -servername localhost </dev/null 2>/dev/null | openssl x509 -noout -checkend 0; echo "exit=$?"
exit=1                                      # 1 = expired / expires within the given seconds
```

## Root cause

The server certificate in `lab.p12` passed its `notAfter` date. Nothing renewed it, and nothing warned before it expired.

## Fix – renew without restarting the server

1. Put a new certificate into the keystore (in production: the certificate issued by the CA):

```bash
keytool -delete -alias lab -keystore .../lab.p12 -storepass changeit
keytool -genkeypair -alias lab -keyalg RSA -keysize 2048 -validity 365 \
  -dname "CN=localhost, O=Lab, C=CZ" -ext "SAN=dns:localhost,ip:127.0.0.1" \
  -keystore .../lab.p12 -storetype PKCS12 -storepass changeit
```

2. Make Elytron re-read the file and re-initialise the key manager – **no reload, no downtime**:

```text
$ jboss-cli.sh --connect --command="/subsystem=elytron/key-store=labKS:load"
{"outcome" => "success", "result" => undefined}
$ jboss-cli.sh --connect --command="/subsystem=elytron/key-manager=labKM:init"
{"outcome" => "success"}
```

Replacing the file alone changes nothing – Elytron keeps the old key store in memory until `:load` + `:init` (or a `reload`).

## Verification

```text
$ openssl s_client -connect localhost:8443 -servername localhost </dev/null 2>/dev/null | openssl x509 -noout -dates
notBefore=Nov  2 13:27:47 2026 GMT
notAfter=Nov  2 13:27:47 2027 GMT

$ curl -sS --cacert tls/lab.crt https://localhost:8443/app/health; echo "exit=$?"
OK
exit=0

$ ... | openssl x509 -noout -checkend 2592000; echo "exit=$?"     # 30 days
exit=0
```

## Prevention

- Monitor expiry, not just availability: [`scripts/check-cert.sh`](../scripts/check-cert.sh) returns `0` OK, `1` WARNING (< 30 days), `2` CRITICAL (expired), `3` UNKNOWN – the convention Nagios and Zabbix use.

```text
$ scripts/check-cert.sh -H localhost -p 8443 -d 30
OK       localhost:8443 ... – expires Nov  2 13:27:47 2027 GMT (more than 30 days left)
```

- Automate renewal (ACME / cert-manager on Kubernetes / an internal CA with an API); public certificate lifetimes are shrinking towards 47 days, so manual renewal does not scale.
- Keep an inventory of certificates and owners; expiry is a calendar problem as much as a technical one.
- Renew with `:load` + `:init` and verify with `openssl s_client` that the **new** certificate is actually served.
- Never commit private keys or keystores to Git; in Kubernetes keep them in a Secret mounted into the pod.
