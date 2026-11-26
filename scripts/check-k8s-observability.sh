#!/usr/bin/env bash
# Observability check: fails if the local overlay lost a piece of the in-cluster telemetry setup.
# The pieces live in k8s/components/observability/ and in k8s/overlays/local/ (LOCAL-K8S.md, "Observability").
#
# Usage: scripts/check-k8s-observability.sh [overlay]   (from the jbh-deploy folder; CI runs it on every PR)
# It only renders YAML. It starts nothing and needs no cluster.
# k8s/overlays/local/.env.k8s must exist, because the Secret generator reads it. CI copies the example.
set -euo pipefail

overlay="${1:-k8s/overlays/local}"
rendered=$(kubectl kustomize --load-restrictor LoadRestrictionsNone "$overlay")

# Prints the first rendered object of this kind whose name starts with the prefix.
# A prefix, because generated names get a hash (jbh-postgres-initdb-<hash>).
object() {
  awk -v kind="$1" -v name="$2" '
    function flush() {
      if (doc != "" && k && n && !done) { printf "%s", doc; done = 1 }
      doc = ""; k = 0; n = 0
    }
    /^---$/ { flush(); next }
    { doc = doc $0 "\n" }
    $0 == "kind: " kind { k = 1 }
    index($0, "  name: " name) == 1 { n = 1 }
    END { flush() }
  ' <<< "$rendered"
}

# expect <object text> <fixed text> <where it belongs>: prints what is missing and returns 1.
expect() {
  if ! grep -qF -- "$2" <<< "$1"; then
    echo "  missing '$2' -> $3" >&2
    return 1
  fi
}

# reject <object text> <fixed text> <why>: the text must NOT be there. Prints the problem and returns 1.
reject() {
  if grep -qF -- "$2" <<< "$1"; then
    echo "  must not contain '$2' -> $3" >&2
    return 1
  fi
}

# expect_object <kind> <name> <file>: the object must exist. Prints the object, or a message and returns 1.
expect_object() {
  local found
  found=$(object "$1" "$2")
  if [ -z "$found" ]; then
    echo "  no $1 $2 -> $3" >&2
    return 1
  fi
  printf '%s' "$found"
}

component=k8s/components/observability

check_otel_env() {
  local rc=0 cm o
  for cm in jbh-iam-config jbh-personal-finance-config jbh-notification-config jbh-gateway-config; do
    o=$(expect_object ConfigMap "$cm" "k8s/base") || { rc=1; continue; }
    expect "$o" 'OTEL_SDK_DISABLED: "false"' "$component/otel-env.yaml ($cm)" || rc=1
    expect "$o" 'OTEL_EXPORTER_OTLP_ENDPOINT: http://jbh-alloy:4317' "$component/otel-env.yaml ($cm)" || rc=1
  done
  # Without a pod template change, running pods keep their old env when the component is turned on.
  local d
  for d in jbh-iam jbh-personal-finance jbh-notification jbh-gateway; do
    o=$(expect_object Deployment "$d" "k8s/base") || { rc=1; continue; }
    expect "$o" 'jbh.kkpa/observability: "on"' "$component/otel-rollout.yaml ($d)" || rc=1
  done
  return $rc
}

check_alloy_deployment() {
  local rc=0 o f="$component/alloy-deployment.yaml"
  o=$(expect_object Deployment jbh-alloy "$f") || return 1
  expect "$o" 'image: grafana/alloy:v1.22.0' "$f" || rc=1
  expect "$o" 'serviceAccountName: jbh-alloy' "$f" || rc=1
  expect "$o" '/etc/alloy/entry/config.alloy' "$f" || rc=1
  expect "$o" 'mountPath: /etc/alloy/modules' "$f" || rc=1
  expect "$o" 'mountPath: /etc/alloy/entry' "$f" || rc=1
  expect "$o" 'name: JBH_PG_MONITOR_DSN' "$f" || rc=1
  # The Faro receiver must not fetch client-given sourcemap URLs (SSRF from /collect).
  if o=$(expect_object ConfigMap jbh-alloy-entry "k8s/overlays/local/kustomization.yaml"); then
    expect "$o" 'download = false' "observability/alloy/k8s-local.alloy (faro.receiver sourcemaps)" || rc=1
  else
    rc=1
  fi
  return $rc
}

check_alloy_service() {
  local rc=0 o p f="$component/alloy-service.yaml"
  o=$(expect_object Service jbh-alloy "$f") || return 1
  # The whole line, not a substring: "port: 4317" must not match "port: 43170" or "targetPort: 4317".
  for p in 4317 4318 12345 12347; do
    if ! grep -qE "^[[:space:]]*(- )?port: $p$" <<< "$o"; then
      echo "  missing 'port: $p' -> $f" >&2
      rc=1
    fi
  done
  return $rc
}

check_alloy_rbac() {
  local rc=0 o f="$component/alloy-rbac.yaml"
  expect_object ServiceAccount jbh-alloy "$f" >/dev/null || rc=1
  # Cluster-wide: only nodes, and only the kubelet's /metrics path. nodes/proxy would allow exec in any pod.
  if o=$(expect_object ClusterRole jbh-alloy "$f"); then
    expect "$o" 'nodes/metrics' "$f (ClusterRole)" || rc=1
    reject "$o" 'nodes/proxy' "$f (ClusterRole): kubelet exec in every pod" || rc=1
    reject "$o" 'pods' "$f (ClusterRole): pods belong in the namespaced Role" || rc=1
  else
    rc=1
  fi
  # Pods and their logs only in the jbh namespace.
  if o=$(expect_object Role jbh-alloy "$f"); then
    expect "$o" 'pods/log' "$f (Role)" || rc=1
    expect "$o" 'namespace: jbh' "$f (Role)" || rc=1
  else
    rc=1
  fi
  if o=$(expect_object RoleBinding jbh-alloy "$f"); then
    expect "$o" 'kind: Role' "$f (RoleBinding roleRef)" || rc=1
    expect "$o" 'kind: ServiceAccount' "$f (RoleBinding subject)" || rc=1
  else
    rc=1
  fi
  if o=$(expect_object ClusterRoleBinding jbh-alloy "$f"); then
    expect "$o" 'kind: ServiceAccount' "$f (ClusterRoleBinding subject)" || rc=1
    expect "$o" 'namespace: jbh' "$f (ClusterRoleBinding subject)" || rc=1
  else
    rc=1
  fi
  return $rc
}

check_faro_ingress() {
  local rc=0 o f="$component/faro-ingress.yaml"
  o=$(expect_object Ingress jbh-faro "$f") || return 1
  expect "$o" 'ingressClassName: traefik' "k8s/overlays/local/patches/ingress-traefik-faro.yaml" || rc=1
  expect "$o" 'path: /collect' "$f" || rc=1
  expect "$o" 'name: jbh-alloy' "$f (backend)" || rc=1
  expect "$o" 'number: 12347' "$f (backend)" || rc=1
  return $rc
}

check_postgres_monitor() {
  local rc=0 o f="$component/postgres-monitor.yaml" g="$component/kustomization.yaml"
  if o=$(expect_object StatefulSet jbh-postgres "k8s/components/postgres"); then
    expect "$o" 'shared_preload_libraries=pg_stat_statements' "$f" || rc=1
    expect "$o" 'name: JBH_PG_MONITOR_PASSWORD' "$f" || rc=1
    expect "$o" 'path: sql/pg-monitor.sql' "$f" || rc=1
  else
    rc=1
  fi
  if o=$(expect_object ConfigMap jbh-postgres-initdb "k8s/components/postgres"); then
    expect "$o" '02-create-monitor-role.sh:' "$g (configMapGenerator, behavior: merge)" || rc=1
    expect "$o" 'pg-monitor.sql:' "$g (configMapGenerator, behavior: merge)" || rc=1
  else
    rc=1
  fi
  return $rc
}

check_web_runtime_config() {
  local rc=0 o f="$component/web-runtime-config.yaml"
  if o=$(expect_object Deployment jbh-web "k8s/base/jbh-web"); then
    expect "$o" 'mountPath: /srv/runtime-config.js' "$f" || rc=1
    expect "$o" 'subPath: runtime-config.js' "$f" || rc=1
  else
    rc=1
  fi
  if o=$(expect_object ConfigMap jbh-web-runtime "k8s/overlays/local/kustomization.yaml (configMapGenerator)"); then
    expect "$o" 'enabled: true' "k8s/overlays/local/jbh-web-runtime-config.js" || rc=1
    expect "$o" 'http://localhost:8081/collect' "k8s/overlays/local/jbh-web-runtime-config.js" || rc=1
  else
    rc=1
  fi
  return $rc
}

failed=0
for check in check_otel_env check_alloy_deployment check_alloy_service check_alloy_rbac check_faro_ingress check_postgres_monitor check_web_runtime_config; do
  if ! "$check"; then
    echo "FAILED: $check" >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "Observability objects are in place."
