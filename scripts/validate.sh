#!/usr/bin/env sh
set -eu

required_files="kustomization.yaml configs/prometheus/prometheus.yml configs/otel-collector/config.yaml configs/tempo/tempo.yaml configs/loki/loki.yaml configs/alloy/config.alloy configs/grafana/provisioning/alerting/alerts.yaml"
for file in $required_files; do
  test -s "$file" || { echo "Missing required file: $file" >&2; exit 1; }
done

if grep -RInE '(secret_key: [^$]|access_key: [^$]|webhook_url: https?://)' configs kube; then
  echo "Potential hardcoded secret found." >&2
  exit 1
fi

# The CI image includes Node.js. Keep this conditional so contributors can run
# the lightweight validation locally without installing it, while CI catches
# malformed Grafana dashboard JSON.
if command -v node >/dev/null 2>&1; then
  for dashboard in configs/grafana/dashboards/*.json; do
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$dashboard"
  done
fi

echo "Static repository validation passed."
