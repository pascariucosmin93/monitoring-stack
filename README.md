# Observability

Stack de monitorizare pentru clusterul Kubernetes (k3s): metrici de infrastructură, alerte
Grafana-managed, probe HTTP, loguri centralizate și trace-uri OpenTelemetry. Se livrează cu Argo CD
(GitOps): un push în `main` și clusterul se sincronizează.

## Componente

- Prometheus: metrici cu retenție de 30 zile și plafon de 4 GB;
- Grafana: dashboard-uri, explorare trace-uri/loguri și alerte gestionate nativ (notificări pe Discord).
  Rulează într-o replică, cu starea într-o bază PostgreSQL externă (nu pe volum local). La un deploy
  podul nou pornește înaintea celui vechi (`RollingUpdate`), deci accesul nu se întrerupe; în cele
  câteva secunde de suprapunere alertele fac schimb de stare prin gossip (HA), ca să nu vină duble;
- node-exporter (DaemonSet) și cAdvisor (din kubelet): metrici de nod și de container;
- kube-state-metrics: starea obiectelor Kubernetes (replici, reporniri, noduri ready);
- blackbox-exporter: probe pentru CalculatorGaz;
- Loki + Alloy (DaemonSet): loguri de pod, păstrate 30 de zile într-un bucket Cloudflare R2;
- OpenTelemetry Collector: metrici RED din toate span-urile (înainte de sampling), tail sampling,
  filtrare de date sensibile și export OTLP;
- Tempo: trace-uri păstrate 7 zile într-un bucket Cloudflare R2.

## Ce se monitorizează pe Kubernetes

| Zonă | Sursă (job Prometheus) | Alerte principale |
|---|---|---|
| Noduri | `node` (node-exporter), `kubelet` | disc, CPU, RAM, inode-uri, ceas, repornire, presiune (Memory/Disk/PID), request-uri de memorie > 90% din alocabil |
| Workload-uri | `kube-state-metrics`, `cadvisor` | container care nu pornește (CrashLoop, ImagePull, config), pod not ready / Pending, crash loop, OOM, memorie aproape de limită, Job eșuat |
| Volume | `kubelet` (`kubelet_volume_stats_*`), `kube-state-metrics` | PVC nelegat, volum > 85% |
| Control plane | `apiserver`, `coredns` | erori 5xx, latență p99, SERVFAIL |
| GitOps | `argocd` | aplicație OutOfSync > 15 min, Degraded/Missing, Argo CD nu poate citi Git |
| Acces public | `public-endpoints`, `calculatorgaz-public` | argo / grafana / gitea / gaz indisponibile prin Cloudflare Tunnel |
| Telemetrie | `loki`, `alloy`, `tempo`, `grafana`, `otel-collector` | țintă căzută, loguri pierdute |

Dashboard-uri: **Kubernetes · Cluster operations**, **Kubernetes · Workloads** (filtru pe namespace) și
**Kubernetes · Control plane & GitOps**. Nu sunt colectate metrici etcd, scheduler și controller-manager
(k3s nu le expune implicit).

Proxmox (hipervizorul) este monitorizat din exterior, prin ținte statice (`192.168.1.30:9100` și `:9221`).

## Runner Gitea și backup-urile PostgreSQL în R2

Mașini din afara clusterului, citite prin ținte statice (node-exporter pe `:9100`, instalat cu Ansible din
repo-ul `infra`, `postgres-backup/`):

| Job Prometheus | Țintă | Ce se vede |
|---|---|---|
| `runner` | `192.168.1.35` (toate containerele `act_runner`) | disc, CPU, RAM, I/O |
| `postgres-hosts` | `192.168.1.16`, `192.168.1.17` | sistem + metrici de backup din textfile collector |

Dashboard: **Infrastructure → Infrastructură — Runner & Backup R2** (`infra-runner-backups`): ocuparea discului
runnerului cu estimare de umplere, vârsta ultimului backup (pgBackRest, full și dump logic), momentul și
durata fiecărui backup, dimensiunea adăugată în R2, mărimea repository-ului, WAL arhivat și erori.

Metricile de backup vin din scripturile de pe serverele Postgres: `backup_*` (rezultatul ultimei rulări),
`pgbackrest_*` (conținutul repository-ului R2, citit cu `pgbackrest info`), `pg_archiver_*` (arhivarea WAL),
`pg_backup_is_primary` (doar primarul face backup, deci alertele se aplică doar lui).

Alerte (folder **Infrastructure**, notificări pe Discord):

| Alertă | Condiție | Severitate |
|---|---|---|
| Runner disk above 80% | ocupare > 80% timp de 10 min | warning |
| Runner disk above 90% | ocupare > 90% timp de 5 min | critical |
| No pgBackRest backup in R2 for 26 hours | niciun backup pgBackRest nou | critical |
| No full pgBackRest backup in R2 for 8 days | niciun full (se face duminică) | critical |
| Cannot read the pgBackRest repository in R2 | primarul nu poate citi R2 / stanza lipsă | critical |
| No successful logical dump to R2 for 26 hours | niciun `pg_dump` încărcat | critical |
| Last backup run failed | ultima rulare a unui backup a eșuat | critical |
| PostgreSQL WAL archiving to R2 is failing | eșecuri la arhivarea WAL | critical |

Un runner sau un server Postgres căzut este prins de regula generală *Monitoring target unavailable*.


## Metrici interne PostgreSQL 18

SQL Exporter rulează în Kubernetes, în namespace-ul `observability`: câte un Deployment pentru
`192.168.1.16` (`postgress`) și `192.168.1.17` (`postgress-1`). Nu instalează nimic pe serverele
PostgreSQL. Citește statistici prin conexiuni TLS pe portul 5432, cu un rol dedicat `pg_monitor`;
Prometheus citește exporterii la fiecare 30 de secunde. Rolul primar/replică este descoperit din SQL,
deci nu este legat de IP în cazul unei promovări. Topologia așteptată este un primar și o replică.

Dashboard în folderul **Infrastructure**: **PostgreSQL — Stare internă & replicare**
(`postgres-internals`), cu filtru după server. Interogările sunt în
`configs/postgres/sql-exporter.yml`, fără text SQL al aplicațiilor, parole sau PID-uri în etichete.

| Semnal | Alertă |
|---|---|
| Conexiuni client / sloturi disponibile (fără sloturile rezervate) | > 80% timp de 10 min; > 90% timp de 5 min |
| Tranzacție veche, inclusiv idle in transaction | > 5 min timp de încă 5 min |
| Sesiuni blocate și timpul real de așteptare din `pg_locks.waitstart` | așteptare > 60 s timp de 2 min |
| Deadlock-uri pe bază de date | creștere în ultimele 10 min |
| Primar fără replică streaming / replică fără WAL receiver streaming | timp de 5 min |
| WAL neaplicat de replică, măsurat pe primar | > 64 MiB timp de 5 min |
| WAL reținut de fiecare replication slot | > 1 GiB timp de 10 min |
| Replication slot cu `wal_status=lost` | timp de 1 min |
| Metrici interne absente pentru fiecare server | lipsesc 5 min, apoi condiția persistă încă 2 min |

Pragurile sunt puncte de pornire și se ajustează după volumul de scrieri și capacitatea discurilor.
Dashboard-ul arată și `replay_lag` în secunde; NULL devine zero când PostgreSQL nu raportează lag.
Alerta folosește backlog-ul în bytes, evitând calculul eronat al întârzierii din vârsta ultimei
tranzacții pe o bază fără scrieri. Deconectarea replicii are alertă separată, deoarece atunci
seria cu backlog poate dispărea. Sloturile inexistente nu declanșează alerte.

### Activare

1. Rulează pe **primarul curent**, ca administrator PostgreSQL, fișierul
   `scripts/postgres-monitoring-role.sql`, cu `psql -X -v ON_ERROR_STOP=1 -f <fișier>`.
   Creează `observability_monitor`, acordă `pg_monitor` și CONNECT la baza `postgres`, setează
   tranzacții read-only implicit și timeout SQL de 5 s, apoi cere parola interactiv.
   Rolul și parola ajung pe replica fizică prin replicare. Nu este necesară o extensie sau restart.
2. Pe **ambele servere**, permite în `pg_hba.conf` accesul rolului la baza `postgres` doar din
   adresele sursă folosite de nodurile Kubernetes, apoi reîncarcă configurația. Exemplu de regulă
   (înlocuiește CIDR-ul cu sursa reală; nu folosi acces general):

   ```text
   hostssl postgres observability_monitor <CIDR-sursă-Kubernetes> scram-sha-256
   ```

   Verifică și firewall-ul către portul 5432. DSN-urile folosesc `sslmode=require`, care criptează
   conexiunea; pentru verificarea identității serverului folosește `verify-full` și montează CA-ul.
3. În Vault, mount-ul KV v2 `kv`, creează calea
   `prod/observability/observability_monitor` cu proprietățile `postgress_dsn` și
   `postgress_1_dsn`. Fiecare valoare este un DSN complet:

   ```text
   postgresql://observability_monitor:<parola-URL-encoded>@192.168.1.16:5432/postgres?sslmode=require&connect_timeout=5&application_name=observability-postgres
   postgresql://observability_monitor:<parola-URL-encoded>@192.168.1.17:5432/postgres?sslmode=require&connect_timeout=5&application_name=observability-postgres
   ```

   `kube/postgres-monitoring-secret.yaml` definește un ExternalSecret care citește cele două
   proprietăți prin ClusterSecretStore-ul existent `vault-kv` și creează secretul Kubernetes
   `postgres-monitoring` în `observability`. Sincronizarea este la fiecare minut. Operatorul
   External Secrets și store-ul Vault trebuie să existe înainte de deploy.

   Pentru o instalare fără External Secrets, exclude manifestul respectiv din kustomization
   și creează manual secretul cu `python3 scripts/create-postgres-monitoring-secret.py`.
   Scriptul cere parola ascuns și nu o salvează în fișiere locale. Nu folosi scripturile de
   creare manuală a secretului când acesta este gestionat de Vault.
4. Livrează modificările prin fluxul Argo CD existent. Verifică cele două Deployment-uri
   `postgres-exporter-postgress` și `postgres-exporter-postgress-1`, apoi în Prometheus:
   `up{job="postgres-internal"}` trebuie să fie 1 pentru ambele ținte.

Fără secret, exporterii nu pornesc; pregătește contul, accesul și secretul înainte de sincronizare.
O eroare de autentificare sau de interogare produce un scrape eșuat, prins și de alerta generală
*Monitoring target unavailable*. Probele de sănătate ale podurilor verifică serverul HTTP al exporterului,
fără interogări SQL. La rotația parolei, actualizează secretul și repornește ambele Deployment-uri.

### Teste PostgreSQL

```bash
python3 scripts/tests/test-postgres-internals.py
```

Necesită Docker, Python 3 și PyYAML. Testul rulează și în CI: pornește un primar și o replică
**PostgreSQL 18** plus exporterii reali într-o rețea Docker izolată, fără porturi publicate.
Verifică permisiunile rolului, colectarea HTTP, blocări reale, tranzacții lungi, deadlock-uri,
backlog de replicare, sloturi care rețin WAL și deconectarea replicii. Containerele și volumele
temporare sunt eliminate la final. Nu se conectează la bazele de producție.

## Structura repo-ului

| Cale | Ce conține |
|---|---|
| `kustomization.yaml` | Punctul de intrare pentru Argo CD (`path: .`). Rădăcina repo-ului, fiindcă kustomize citește fișiere doar de sub directorul lui. |
| `kube/` | Manifestele Kubernetes (un fișier per componentă) |
| `configs/` | Configurările aplicațiilor (Prometheus, Loki, Tempo, Alloy, OTel, Blackbox, Grafana), incluse în ConfigMap-uri prin `configMapGenerator` |
| `configs/grafana/` | Datasource-uri, dashboard-uri și reguli de alertă provisionate |
| `argocd/observability.yaml` | Aplicația Argo CD (se aplică o singură dată) |
| `scripts/` | Validare și crearea secretelor |

Serviciile Kubernetes se numesc `prometheus`, `loki`, `tempo`, `otel-collector` ș.a., deci URL-urile din
`configs/grafana/provisioning/datasources/datasources.yaml` sunt scurte și rămân valide în namespace-ul `observability`.

## Instalare

```bash
# 1. Secretele (nu sunt în Git): un fișier per cheie în ./secrets, apoi
scripts/create-kube-secrets.sh
# 2. Aplicația Argo CD (o singură dată). Repo-ul trebuie adăugat în Argo CD dacă e privat.
kubectl apply -f argocd/observability.yaml
```

Fișierele din `./secrets`: `grafana_admin_password`, `grafana_security_secret_key`,
`grafana_discord_webhook`, `grafana_smtp_key`, `grafana_smtp_user`, `grafana_root_url`,
`loki_r2_access_key`, `loki_r2_secret_key`, `tempo_r2_access_key`, `tempo_r2_secret_key`,
`tempo_r2_endpoint` (doar hostul S3 R2, fără `https://`), `tempo_r2_bucket`.
Tokenul dintre Grafana și renderer se generează automat.

### Baza de date a Grafana

Grafana folosește PostgreSQL (`postgress.cosmin.home`), baza `grafana`, utilizatorul `grafana`. Secretul
`grafana-db` (chei: `host`, `port`, `name`, `user`, `password`) se creează din `./secrets/grafana_db_*`
(opțional: scriptul îl lasă neschimbat dacă fișierele lipsesc). Baza și rolul se creează o singură dată,
cu un utilizator administrator:

```sql
CREATE ROLE grafana LOGIN PASSWORD '<parola>';
CREATE DATABASE grafana OWNER grafana;
REVOKE ALL ON DATABASE grafana FROM PUBLIC;
```

La prima pornire Grafana rulează migrările (~1 minut). Dashboard-urile, alertele și datasource-urile vin
din Git; utilizatorii creați doar din interfață și preferințele sunt în baza de date.

Grafana nu are Ingress: se expune prin tunelul Cloudflare spre
`http://grafana.observability.svc.cluster.local:3000`. Protejeaz-o cu Cloudflare Access.

## Securitate

Prometheus, Loki, Tempo și Collector sunt servicii `ClusterIP`: nu sunt expuse în afara clusterului.
Secretele sunt create manual în cluster și nu apar în Git. Podurile folosesc `runAsNonRoot` și elimină
capabilitățile Linux; Grafana nu montează token-ul de service account (secretele ei sunt la `/run/secrets`).

## Alerte Grafana

Regulile de infrastructură sunt provisionate în Grafana și interoghează direct Prometheus;
Alertmanager nu face parte din stack. Contact point-ul `discord` citește webhook-ul din secretul
`grafana-secrets`, prin variabila `DISCORD_WEBHOOK` setată la pornirea containerului.

Regulile folosesc expresii `threshold` aplicate direct pe query-ul instant, nu `classic_conditions`:
fiecare serie (nod, țintă, pod) devine o alertă separată, cu etichetele ei în notificare. Query-ul
trebuie să întoarcă valoarea măsurată (de exemplu `up`, cu prag `< 1`), nu un filtru de tip `up == 0`,
a cărui valoare 0 nu depășește niciodată pragul `> 0`.

Pentru reguli noi, editează `configs/grafana/provisioning/alerting/alerts.yaml` și fă push. Regulile
provisionate sunt read-only în interfața Grafana, deci configurația din Git rămâne sursa de adevăr.
O regulă ștearsă sau redenumită se adaugă și în `deleteRules`, altfel rămâne în baza de date Grafana.

Dashboard-urile din `configs/grafana/dashboards/` se actualizează la fel. Un dashboard nou trebuie
adăugat și în `kustomization.yaml`, la `grafana-dashboards` (sau `grafana-dashboards-proxmox`). Grafana
se actualizează la fiecare modificare de configurare prin rolling update, fără întrerupere (pod nou, apoi
se oprește cel vechi). Ce editezi doar din interfață
nu ajunge în Git: exportă JSON-ul și pune-l în repo.

## Integrarea CalculatorGaz

CalculatorGaz rulează în namespace-ul `gaz` (repo-ul `gaz-kube`). Prometheus și blackbox colectează de
acolo; politicile de rețea din `gaz-kube` permit accesul din `observability`. Telemetria OTLP trebuie
trimisă la Collector:

```text
OTEL_SERVICE_NAME=calculatorgaz
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production,service.version=<git-sha>
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

Instrumentarea aplicației se păstrează în repo-ul `gaz`, prin `instrumentation.ts`. Nu trimite body-uri
HTTP, cookie-uri, tokenuri, parole, text OCR sau conținut de facturi în atributele trace-urilor.

## Validare locală

```bash
sh scripts/validate.sh           # verificări statice, fără Docker
sh scripts/validate-configs.sh   # promtool (config + interogări de alertă), otelcol, Loki, Alloy, YAML, kustomize + kubeconform
```

`validate-configs.sh` folosește exact versiunile de imagini din `kube/*.yaml` și rulează și în CI.

După deploy:

```bash
kubectl -n observability get pods
kubectl -n observability logs deploy/prometheus
kubectl -n argocd get application observability
```

## Operațiuni

Nu pune secrete în ConfigMap-uri sau în variabile din manifeste. Pentru rotație, actualizează
fișierul din `./secrets`, rulează din nou `scripts/create-kube-secrets.sh` și repornește podul
(`kubectl -n observability rollout restart deploy/<nume>`); variabilele de mediu se citesc doar la pornire.
Urmărește spațiul volumului `tempo-wal` înainte de actualizarea configurației Tempo.
