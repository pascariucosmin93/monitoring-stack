#!/usr/bin/env bash
# Creează Secretele pentru varianta Kubernetes din ./secrets (un fișier per cheie, ignorat de git).
# Secretele nu sunt în Git; Argo CD nu le gestionează și nu le șterge.
#   mkdir -p secrets && printf '%s' 'valoare' > secrets/grafana_admin_password   # etc.
#   scripts/create-kube-secrets.sh
set -euo pipefail
cd "$(dirname "$0")/.."

need() {
  local missing=0 f
  for f in "$@"; do
    [ -s "secrets/$f" ] || { echo "LIPSEȘTE: secrets/$f"; missing=1; }
  done
  [ "$missing" = 0 ] || { echo "Completează fișierele de mai sus și rulează din nou."; exit 1; }
}

need grafana_admin_password grafana_security_secret_key grafana_discord_webhook \
     grafana_smtp_key grafana_smtp_user grafana_root_url \
     loki_r2_access_key loki_r2_secret_key \
     tempo_r2_access_key tempo_r2_secret_key tempo_r2_endpoint tempo_r2_bucket

# Tokenul dintre Grafana și renderer: generat o singură dată, păstrat la rulările următoare.
if [ ! -s secrets/grafana_renderer_token ]; then
  head -c 32 /dev/urandom | base64 | tr -d '=+/\n' > secrets/grafana_renderer_token
fi

kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

apply() {
  kubectl -n observability create secret generic "$@" --dry-run=client -o yaml | kubectl apply -f -
}

apply grafana-secrets \
  --from-file=admin_password=secrets/grafana_admin_password \
  --from-file=security_secret_key=secrets/grafana_security_secret_key \
  --from-file=discord_webhook=secrets/grafana_discord_webhook \
  --from-file=smtp_key=secrets/grafana_smtp_key \
  --from-file=smtp_user=secrets/grafana_smtp_user \
  --from-file=root_url=secrets/grafana_root_url \
  --from-file=renderer_token=secrets/grafana_renderer_token

# Baza de date a Grafana (PostgreSQL). Opțional aici: dacă fișierele lipsesc, secretul grafana-db rămâne
# cel existent în cluster. Valorile: host, port, bază, utilizator, parolă.
if [ -s secrets/grafana_db_password ]; then
  need grafana_db_host grafana_db_port grafana_db_name grafana_db_user
  apply grafana-db \
    --from-file=host=secrets/grafana_db_host \
    --from-file=port=secrets/grafana_db_port \
    --from-file=name=secrets/grafana_db_name \
    --from-file=user=secrets/grafana_db_user \
    --from-file=password=secrets/grafana_db_password
fi

# SQL Exporter PostgreSQL: DSN-uri complete cu utilizatorul dedicat și sslmode=require.
# Opțional: păstrează secretul existent dacă fișierele nu sunt furnizate.
if [ -s secrets/postgres_monitoring_postgress_dsn ] || [ -s secrets/postgres_monitoring_postgress_1_dsn ]; then
  need postgres_monitoring_postgress_dsn postgres_monitoring_postgress_1_dsn
  apply postgres-monitoring \
    --from-file=postgress_dsn=secrets/postgres_monitoring_postgress_dsn \
    --from-file=postgress_1_dsn=secrets/postgres_monitoring_postgress_1_dsn
fi

apply loki-r2 \
  --from-file=access_key=secrets/loki_r2_access_key \
  --from-file=secret_key=secrets/loki_r2_secret_key

apply tempo-r2 \
  --from-file=access_key=secrets/tempo_r2_access_key \
  --from-file=secret_key=secrets/tempo_r2_secret_key \
  --from-file=endpoint=secrets/tempo_r2_endpoint \
  --from-file=bucket=secrets/tempo_r2_bucket

echo "Secretele din namespace-ul observability au fost create. Șterge ./secrets după verificare."
