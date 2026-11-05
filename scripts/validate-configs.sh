#!/usr/bin/env sh
# Validates every service configuration with the same image versions that the
# Kubernetes manifests deploy. Configs are passed on stdin rather than bind-mounted,
# so the script also works on a CI runner that talks to a remote Docker daemon.
set -eu

cd "$(dirname "$0")/.."

# Resolve an image from the manifest that deploys it.
manifest_image() {
  sed -n "s|^ *image: \($1[^ ]*\).*|\1|p" "kube/$2" | head -n 1
}

PROMETHEUS_IMAGE=$(manifest_image prom/prometheus prometheus.yaml)
OTELCOL_IMAGE=$(manifest_image otel/opentelemetry-collector-contrib otel-collector.yaml)
ALLOY_IMAGE=$(manifest_image grafana/alloy alloy.yaml)
LOKI_IMAGE=$(manifest_image grafana/loki loki.yaml)
SQL_EXPORTER_IMAGE=$(manifest_image burningalchemist/sql_exporter postgres-exporter.yaml)
YQ_IMAGE=mikefarah/yq:4.47.1
K8S_TOOLS_IMAGE=alpine/k8s:1.31.0

for image in "$PROMETHEUS_IMAGE" "$OTELCOL_IMAGE" "$ALLOY_IMAGE" "$LOKI_IMAGE" "$SQL_EXPORTER_IMAGE"; do
  test -n "$image" || { echo "Could not resolve an image version from kube/*.yaml" >&2; exit 1; }
done

step() { printf '\n==> %s\n' "$1"; }

# promtool checks that the in-cluster token and CA files exist; create empty stand-ins.
step "Prometheus configuration ($PROMETHEUS_IMAGE)"
docker run --rm -i --user 0 --entrypoint sh "$PROMETHEUS_IMAGE" \
  -c 'mkdir -p /var/run/secrets/kubernetes.io/serviceaccount && touch /var/run/secrets/kubernetes.io/serviceaccount/token /var/run/secrets/kubernetes.io/serviceaccount/ca.crt && cat > /tmp/prometheus.yml && promtool check config /tmp/prometheus.yml' \
  < configs/prometheus/prometheus.yml

# Grafana alert queries are plain PromQL; wrap them in a recording-rule file so
# promtool can reject a typo before Grafana evaluates it in production.
step "Grafana alert queries (PromQL syntax, $PROMETHEUS_IMAGE)"
docker run --rm -i "$YQ_IMAGE" e \
  '{"groups":[{"name":"alerts","rules":[.groups[].rules[] | . as $r | $r.data[].model.expr | select(. != null) | {"record":"alert_expr","expr":.,"labels":{"rule":$r.uid}}]}]}' \
  - < configs/grafana/provisioning/alerting/alerts.yaml \
  | docker run --rm -i --entrypoint sh "$PROMETHEUS_IMAGE" \
      -c 'cat > /tmp/rules.yml && promtool check rules /tmp/rules.yml'

step "OpenTelemetry Collector configuration ($OTELCOL_IMAGE)"
docker run --rm -e OTELCOL_CONFIG="$(cat configs/otel-collector/config.yaml)" \
  "$OTELCOL_IMAGE" validate --config=env:OTELCOL_CONFIG

step "Loki configuration ($LOKI_IMAGE)"
docker run --rm -i \
  -e LOKI_R2_BUCKET=ci -e LOKI_R2_ENDPOINT=ci -e LOKI_R2_ACCESS_KEY=ci -e LOKI_R2_SECRET_KEY=ci \
  "$LOKI_IMAGE" -config.file=/dev/stdin -config.expand-env=true -verify-config \
  < configs/loki/loki.yaml

step "Alloy configuration ($ALLOY_IMAGE)"
docker run --rm -i --entrypoint sh "$ALLOY_IMAGE" \
  -c 'cat > /tmp/config.alloy && alloy validate --stability.level=public-preview /tmp/config.alloy' \
  < configs/alloy/config.alloy

step "PostgreSQL SQL Exporter configuration ($SQL_EXPORTER_IMAGE)"
docker run --rm -i --entrypoint sh "$SQL_EXPORTER_IMAGE" \
  -c 'cat > /tmp/sql-exporter.yml && /bin/sql_exporter -config.file=/tmp/sql-exporter.yml -config.check' \
  < configs/postgres/sql-exporter.yml

# Tempo has no offline config validator and Grafana provisioning is only
# checked when Grafana starts; at least reject YAML syntax errors here.
for file in configs/tempo/tempo.yaml configs/blackbox/blackbox.yml configs/grafana/provisioning/*/*.yaml; do
  step "YAML syntax: $file"
  docker run --rm -i "$YQ_IMAGE" e 'true' - < "$file" > /dev/null
done

# The repository is streamed as a tarball, so this also works against a remote Docker daemon.
step "Kubernetes manifests (kustomize build + kubeconform, $K8S_TOOLS_IMAGE)"
tar c kustomization.yaml kube configs scripts/schemas | docker run --rm -i --entrypoint sh "$K8S_TOOLS_IMAGE" \
  -c 'mkdir /w && tar x -C /w && kustomize build /w | kubeconform -strict -summary -kubernetes-version 1.31.0 -schema-location default -schema-location "/w/scripts/schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"'

printf '\nAll service configurations are valid.\n'
