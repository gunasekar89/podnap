#!/usr/bin/env bash
# Sleep Mode for Pods -- Bash >= 4.0; kubectl >= 1.27; Helm 3; jq; curl; Python 3.
# Usage:
#   ./sleep-mode.sh enable -n dev -d orders-api \
#     --prometheus-url http://prometheus.monitoring:9090           # preview
#   ./sleep-mode.sh enable -n dev -d orders-api \
#     --prometheus-url http://prometheus.monitoring:9090 --apply --yes
#   ./sleep-mode.sh status -n dev -d orders-api --apply --yes
#   ./sleep-mode.sh test -n dev -d orders-api --apply --yes
#   ./sleep-mode.sh disable -n dev -d orders-api --apply --yes
#
# Defaults are read-only. --apply authorizes mutations; --yes skips the context
# prompt only with --apply. Status is always read-only. Diagnostics go to stderr;
# enable's stdout is the rendered ScaledObject YAML, including on --apply.
#
# Important: increase(...[2m]) is an estimate, NOT an exact request counter.
# See README.md for timing, scrape delays, the keep-awake trigger, and recovery.
set -euo pipefail
set -E

usage() {
    cat <<'USAGE'
Usage: sleep-mode.sh {enable|disable|status|test} -n NAMESPACE -d DEPLOYMENT [flags]

  -n, --namespace NS           Required (NAMESPACE)
  -d, --deployment NAME        Required (DEPLOYMENT)
  -s, --service NAME           Default: deployment (SERVICE)
      --prometheus-url URL    Required for initial enable; stored for reuse
                              (PROMETHEUS_URL)
      --idle-minutes N        Default: 30 (IDLE_MINUTES)
      --wake-hits N           Default: 3 (WAKE_HITS)
      --max-replicas N        Default: captured original replicas, minimum 1
                              (MAX_REPLICAS)
      --exclude-paths REGEX   Default: /healthz|/readyz|/livez|/health|/ping
                              Empty string disables exclusions (EXCLUDE_PATHS)
      --threshold N           Requests per pod per 2m; default: 50 (THRESHOLD)
      --dry-run               Default: print YAML/plan; no cluster mutations
      --apply                 Actually change resources (APPLY=true)
      --yes                   Skip context prompt only with --apply (YES=true)
      --force                 Allow prod|prd|live contexts; never for test (FORCE)
      --replace-hpa           Back up, then replace a plain HPA (REPLACE_HPA)
      --ingress-namespace NS  Additional protected controller namespace
                              (INGRESS_NAMESPACE); others are auto-discovered
      --prometheus-service S  Port-forward Service override (PROMETHEUS_SERVICE)
      --prometheus-namespace N  Port-forward namespace (PROMETHEUS_NAMESPACE)
      --backup-dir DIR        Default: ./sleep-mode-backups (BACKUP_DIR)
      --test-url URL          Override an ambiguous ingress URL; safe GET only
                              (TEST_URL). Must match an Ingress for this Service.
      --keda-chart-version V  Optional Helm chart pin (KEDA_CHART_VERSION)
  -h, --help

Boolean environment values: true/false. DRY_RUN=true/false is also supported;
if set, it takes precedence over APPLY; command-line mode flags override both.
Prometheus must be reachable through a Kubernetes Service. Authenticated metrics
endpoints require an extension with TriggerAuthentication; do not put credentials
in URLs. Never run concurrent mutations for the same target.
USAGE
}

SUBCOMMAND=''
NAMESPACE=${NAMESPACE:-}
DEPLOYMENT=${DEPLOYMENT:-}
SERVICE=${SERVICE:-}
PROMETHEUS_URL=${PROMETHEUS_URL:-}
IDLE_MINUTES=${IDLE_MINUTES:-30}
WAKE_HITS=${WAKE_HITS:-3}
MAX_REPLICAS=${MAX_REPLICAS:-}
EXCLUDE_PATHS=${EXCLUDE_PATHS-'/healthz|/readyz|/livez|/health|/ping'}
THRESHOLD=${THRESHOLD:-50}
APPLY=${APPLY:-false}
YES=${YES:-false}
FORCE=${FORCE:-false}
REPLACE_HPA=${REPLACE_HPA:-false}
INGRESS_NAMESPACE=${INGRESS_NAMESPACE:-}
PROMETHEUS_SERVICE=${PROMETHEUS_SERVICE:-}
PROMETHEUS_NAMESPACE=${PROMETHEUS_NAMESPACE:-}
BACKUP_DIR=${BACKUP_DIR:-"$PWD/sleep-mode-backups"}
TEST_URL=${TEST_URL:-}
KEDA_CHART_VERSION=${KEDA_CHART_VERSION:-}
CONTEXT='' WORKDIR='' PF_PID='' PROM_HOST='' PROM_PORT='' LOCAL_PORT=''
NAME='' STATE_NAME='' DEP_JSON='' STATE_JSON='' SO_JSON='' CRD_JSON=''
ORIGINAL_REPLICAS='' DEP_UID='' QUERY='' KEEP_QUERY='' REPLICA_QUERY=''
NAMESPACE_LABEL='' SERVICE_LABEL='' KSM_NAMESPACE_LABEL='' KSM_DEPLOYMENT_LABEL=''
PENDING_HPAS='[]' BACKED_HPAS='[]' INITIAL_SUPPORTED=false
ENABLE_DIRTY=false TEST_PATCHED=false RESTORE_FILE='' TEST_UID=''
MANAGER='sleep-mode'
ANNOTATION='sleepmode/original-replicas'
CRD='scaledobjects.keda.sh'
POLL_SECONDS=15

log() {
    local level=$1 color='' reset=''
    shift
    if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
        reset=$'\033[0m'
        case "$level" in
            ERROR) color=$'\033[31m' ;; WARN) color=$'\033[33m' ;;
            OK) color=$'\033[32m' ;; *) color=$'\033[36m' ;;
        esac
    fi
    printf '%s[%s] %-5s %s%s\n' "$color" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        "$level" "$*" "$reset" >&2
}

die() { log ERROR "$*"; exit 1; }
echo_action() {
    local rendered
    printf -v rendered '%q ' "$@"
    log EXEC "$rendered"
}
run() { echo_action "$@"; "$@"; }
k() { run kubectl --context="$CONTEXT" --request-timeout=30s "$@"; }
h() { run helm --kube-context "$CONTEXT" "$@"; }
json_string() { jq -cn --arg value "$1" '$value'; }
need_value() { (( $# >= 2 )) || die "Missing value for $1"; }
boolean() { [[ $2 == true || $2 == false ]] || die "$1 must be true or false."; }
positive_integer() {
    [[ $2 =~ ^[0-9]+$ && ${#2} -le 9 ]] || die "$1 must be a positive integer."
    (( 10#$2 >= 1 && 10#$2 <= 1000000 )) || die "$1 must be between 1 and 1000000."
}
dns_label() {
    [[ ${#2} -le 63 && $2 =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
        die "$1 must be a Kubernetes DNS label (at most 63 characters)."
}
deployment_name() {
    [[ ${#1} -le 253 && $1 =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ && $1 != *..* ]] ||
        die "Invalid Deployment name: $1"
}

parse_args() {
    boolean APPLY "$APPLY"
    if [[ ${DRY_RUN+x} ]]; then
        boolean DRY_RUN "$DRY_RUN"
        if [[ $DRY_RUN == true ]]; then APPLY=false; else APPLY=true; fi
    fi
    while (( $# )); do
        case "$1" in
            enable|disable|status|test)
                [[ -z $SUBCOMMAND ]] || die 'Specify exactly one subcommand.'
                SUBCOMMAND=$1; shift ;;
            -n|--namespace) need_value "$@"; NAMESPACE=$2; shift 2 ;;
            -d|--deployment) need_value "$@"; DEPLOYMENT=$2; shift 2 ;;
            -s|--service) need_value "$@"; SERVICE=$2; shift 2 ;;
            --prometheus-url) need_value "$@"; PROMETHEUS_URL=$2; shift 2 ;;
            --idle-minutes) need_value "$@"; IDLE_MINUTES=$2; shift 2 ;;
            --wake-hits) need_value "$@"; WAKE_HITS=$2; shift 2 ;;
            --max-replicas) need_value "$@"; MAX_REPLICAS=$2; shift 2 ;;
            --exclude-paths) need_value "$@"; EXCLUDE_PATHS=$2; shift 2 ;;
            --threshold) need_value "$@"; THRESHOLD=$2; shift 2 ;;
            --ingress-namespace) need_value "$@"; INGRESS_NAMESPACE=$2; shift 2 ;;
            --prometheus-service) need_value "$@"; PROMETHEUS_SERVICE=$2; shift 2 ;;
            --prometheus-namespace) need_value "$@"; PROMETHEUS_NAMESPACE=$2; shift 2 ;;
            --backup-dir) need_value "$@"; BACKUP_DIR=$2; shift 2 ;;
            --test-url) need_value "$@"; TEST_URL=$2; shift 2 ;;
            --keda-chart-version) need_value "$@"; KEDA_CHART_VERSION=$2; shift 2 ;;
            --dry-run) APPLY=false; shift ;;
            --apply) APPLY=true; shift ;;
            --yes) YES=true; shift ;;
            --force) FORCE=true; shift ;;
            --replace-hpa) REPLACE_HPA=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1 (see --help)" ;;
        esac
    done
    [[ -n $SUBCOMMAND && -n $NAMESPACE && -n $DEPLOYMENT ]] ||
        die 'Subcommand, --namespace and --deployment are required (see --help).'
    SERVICE=${SERVICE:-$DEPLOYMENT}
    dns_label namespace "$NAMESPACE"
    deployment_name "$DEPLOYMENT"
    dns_label service "$SERVICE"
    positive_integer idle-minutes "$IDLE_MINUTES"
    positive_integer wake-hits "$WAKE_HITS"
    positive_integer threshold "$THRESHOLD"
    IDLE_MINUTES=$((10#$IDLE_MINUTES))
    WAKE_HITS=$((10#$WAKE_HITS))
    THRESHOLD=$((10#$THRESHOLD))
    if [[ -n $MAX_REPLICAS ]]; then
        positive_integer max-replicas "$MAX_REPLICAS"
        MAX_REPLICAS=$((10#$MAX_REPLICAS))
    fi
    local flag
    for flag in YES FORCE REPLACE_HPA; do boolean "$flag" "${!flag}"; done
    [[ -z $INGRESS_NAMESPACE ]] || dns_label ingress-namespace "$INGRESS_NAMESPACE"
}

restore_test_settings() {
    log INFO 'Restoring the original cooldown settings.'
    if ! k -n "$NAMESPACE" patch scaledobject "$NAME" --type=json --patch-file="$RESTORE_FILE" >&2; then
        log ERROR "Cooldown restoration failed. Recovery patch: $RESTORE_FILE"
        log ERROR "The recovery patch is also retained in ConfigMap $STATE_NAME (test-restore.json)."
        return 1
    fi
    TEST_PATCHED=false
    k -n "$NAMESPACE" patch configmap "$STATE_NAME" --type=merge \
        -p '{"data":{"test-restore.json":null}}' >&2
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM ERR
    set +e
    if [[ $TEST_PATCHED == true ]]; then restore_test_settings || rc=1; fi
    if [[ -n $PF_PID ]]; then
        kill "$PF_PID" 2>/dev/null
        wait "$PF_PID" 2>/dev/null
    fi
    [[ -z $WORKDIR ]] || rm -rf -- "$WORKDIR"
    if (( rc != 0 )) && [[ $ENABLE_DIRTY == true ]]; then
        log WARN "Recovery state was retained. Re-run enable, or disable -n $NAMESPACE -d $DEPLOYMENT --apply."
    fi
    exit "$rc"
}

common_preflight() {
    (( BASH_VERSINFO[0] >= 4 )) || die 'Bash >= 4 is required (macOS: install a newer Bash).'
    local tool version reply pod_json protected ns_json
    for tool in kubectl helm jq curl python3; do
        command -v "$tool" >/dev/null 2>&1 || die "Missing prerequisite: $tool"
    done
    CONTEXT=$(run kubectl config current-context) || die 'No current kubectl context.'
    [[ -n $CONTEXT ]] || die 'No current kubectl context.'
    log INFO "Context: $CONTEXT | namespace: $NAMESPACE | deployment: $DEPLOYMENT | apply: $APPLY"
    if [[ $SUBCOMMAND == test ]]; then
        [[ ! ${CONTEXT,,} =~ prod|prd|live && ! ${NAMESPACE,,} =~ prod|prd|live ]] ||
            die 'test refuses production-looking contexts AND namespaces, even with --force.'
    elif [[ ${CONTEXT,,} =~ prod|prd|live && $FORCE != true ]]; then
        die 'Context looks like production (prod|prd|live); use --force to override.'
    fi
    [[ $NAMESPACE != kube-system && $NAMESPACE != keda ]] || die "Protected namespace: $NAMESPACE"
    if [[ $APPLY != true || $YES != true ]]; then
        printf 'Confirm context "%s" by typing yes: ' "$CONTEXT" >&2
        read -r reply || die 'Context confirmation required; --apply --yes permits unattended execution.'
        [[ $reply == yes ]] || die 'Context not confirmed.'
    fi
    version=$(k version --client=true -o json)
    jq -e '(.clientVersion.major|tonumber) == 1 and
        (.clientVersion.minor|capture("^(?<n>[0-9]+)").n|tonumber) >= 27' <<<"$version" >/dev/null ||
        die 'kubectl >= 1.27 (major 1) is required.'
    version=$(h version --template '{{.Version}}')
    [[ $version =~ ^v3\. ]] || die 'Helm 3 is required.'
    ns_json=$(k get namespace "$NAMESPACE" -o json)
    DEP_JSON=$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o json) ||
        die "Deployment $NAMESPACE/$DEPLOYMENT does not exist or is unreadable."
    if [[ $SUBCOMMAND == test ]]; then
        protected=$(jq -r '[.metadata.labels // {} | to_entries[] |
            select(.key|test("(^|[./_-])(env|environment|stage|tier)$")) | .value] | join(" ")' \
            <<<"$ns_json"$'\n'"$DEP_JSON")
        [[ ! ${protected,,} =~ prod|prd|live ]] || die 'test refuses production environment labels.'
    fi
    pod_json=$(k get pods -A -l app.kubernetes.io/component=controller -o json) ||
        die 'Cannot discover ingress namespaces; cluster-wide controller Pod read access is required.'
    protected=$(jq -r '.items[] | select(any(.spec.containers[]?;
        .image|test("ingress-nginx/controller(:|@)"))) | .metadata.namespace' <<<"$pod_json")
    if [[ -z $protected && -z $INGRESS_NAMESPACE ]]; then
        die 'Could not identify ingress-nginx Pods. Set --ingress-namespace explicitly.'
    fi
    while IFS= read -r reply; do
        [[ -z $reply || $NAMESPACE != "$reply" ]] || die "Protected ingress namespace: $NAMESPACE"
    done <<<"$protected"$'\n'"$INGRESS_NAMESPACE"
    DEP_UID=$(jq -er '.metadata.uid' <<<"$DEP_JSON")
    NAME=$(python3 - "$DEPLOYMENT" <<'PY'
import hashlib, sys
name = sys.argv[1] + '-sleep-mode'
print(name if len(name) <= 57 else name[:44].rstrip('-.') + '-' + hashlib.sha256(name.encode()).hexdigest()[:12])
PY
    )
    STATE_NAME="$NAME-state"
    WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/sleep-mode.XXXXXXXX")
    CRD_JSON=$(k get crd "$CRD" --ignore-not-found -o json)
    STATE_JSON=$(k -n "$NAMESPACE" get configmap "$STATE_NAME" --ignore-not-found -o json)
    if [[ -n $CRD_JSON ]]; then
        SO_JSON=$(k -n "$NAMESPACE" get scaledobject "$NAME" --ignore-not-found -o json)
        if jq -e 'any(.spec.versions[]; .served == true and
            .schema.openAPIV3Schema.properties.spec.properties.initialCooldownPeriod != null)' \
            <<<"$CRD_JSON" >/dev/null; then INITIAL_SUPPORTED=true; fi
    fi
    validate_ownership
}

validate_ownership() {
    if [[ -n $STATE_JSON ]]; then
        jq -e --arg uid "$DEP_UID" --arg manager "$MANAGER" '
            .metadata.labels["app.kubernetes.io/managed-by"] == $manager and
            .data["deployment-uid"] == $uid' <<<"$STATE_JSON" >/dev/null ||
            die "State ConfigMap $STATE_NAME belongs to another owner or Deployment UID."
        BACKED_HPAS=$(jq -er '.data["hpas.json"]' <<<"$STATE_JSON")
        jq -e 'type == "array"' <<<"$BACKED_HPAS" >/dev/null || die 'Invalid HPA backup in state.'
    fi
    if [[ -n $SO_JSON ]]; then
        jq -e --arg uid "$DEP_UID" --arg d "$DEPLOYMENT" --arg manager "$MANAGER" '
            .metadata.labels["app.kubernetes.io/managed-by"] == $manager and
            .metadata.annotations["sleepmode/deployment-uid"] == $uid and
            .spec.scaleTargetRef.name == $d' <<<"$SO_JSON" >/dev/null ||
            die "ScaledObject $NAME already exists and is not owned by this script for this Deployment."
    fi
    ORIGINAL_REPLICAS=$(jq -r --arg a "$ANNOTATION" '.metadata.annotations[$a] // empty' <<<"$DEP_JSON")
    if [[ -n $ORIGINAL_REPLICAS && -n $STATE_JSON ]]; then
        [[ $ORIGINAL_REPLICAS == "$(jq -er '.data["original-replicas"]' <<<"$STATE_JSON")" ]] ||
            die 'Original replica annotation disagrees with recovery state; refusing an ambiguous restore.'
    fi
    if [[ -z $ORIGINAL_REPLICAS && -n $STATE_JSON ]]; then
        ORIGINAL_REPLICAS=$(jq -er '.data["original-replicas"]' <<<"$STATE_JSON")
    fi
    if [[ -z $ORIGINAL_REPLICAS && -n $SO_JSON ]]; then
        die 'Original replica count is missing; refusing to invent a restore value.'
    fi
    if [[ -z $ORIGINAL_REPLICAS ]]; then ORIGINAL_REPLICAS=$(jq -r '.spec.replicas // 1' <<<"$DEP_JSON"); fi
    [[ $ORIGINAL_REPLICAS =~ ^[0-9]+$ && ${#ORIGINAL_REPLICAS} -le 9 ]] ||
        die 'Invalid original-replicas annotation/state.'
    ORIGINAL_REPLICAS=$((10#$ORIGINAL_REPLICAS))
    if [[ -z $MAX_REPLICAS ]]; then
        if [[ -n $SO_JSON ]]; then MAX_REPLICAS=$(jq -r '.spec.maxReplicaCount' <<<"$SO_JSON");
        else MAX_REPLICAS=$ORIGINAL_REPLICAS; fi
        (( MAX_REPLICAS >= 1 )) || MAX_REPLICAS=1
    fi
    if [[ $SUBCOMMAND != disable && -n $STATE_JSON ]]; then
        jq -e '.data["test-restore.json"] == null' <<<"$STATE_JSON" >/dev/null ||
            [[ $SUBCOMMAND == status ]] || die "An interrupted test needs recovery; see ConfigMap $STATE_NAME."
    fi
}

verify_service() {
    local service_json
    service_json=$(k -n "$NAMESPACE" get service "$SERVICE" -o json) ||
        die "Service $NAMESPACE/$SERVICE does not exist or is unreadable."
    jq -e --argjson deployment "$DEP_JSON" '
        (.spec.selector // {}) as $s | ($s|length)>0 and
        all($s|to_entries[]; $deployment.spec.template.metadata.labels[.key] == .value)' \
        <<<"$service_json" >/dev/null || die 'Service must select the target Deployment Pods.'
}

start_prometheus() {
    # Parse without eval. Original hostname is retained for Host header and TLS SNI.
    if [[ -z $PROMETHEUS_URL && -n $SO_JSON ]]; then
        PROMETHEUS_URL=$(jq -r '.spec.triggers[] | select(.name == "wake") | .metadata.serverAddress' <<<"$SO_JSON")
    fi
    [[ -n $PROMETHEUS_URL ]] || die '--prometheus-url (or PROMETHEUS_URL) is required.'
    python3 - "$PROMETHEUS_URL" >"$WORKDIR/prom-url" <<'PY'
import sys, urllib.parse
try:
    u = urllib.parse.urlsplit(sys.argv[1])
    if u.scheme not in ('http', 'https') or not u.hostname or u.username or u.password or u.query or u.fragment:
        raise ValueError('use http(s)://host[:port][/prefix], without credentials, query or fragment')
    if any(ord(c) < 32 for c in sys.argv[1]) or '%' in u.netloc:
        raise ValueError('invalid URL characters')
    print(u.hostname)
    print(u.port or (443 if u.scheme == 'https' else 80))
    parts = u.hostname.split('.')
    internal = len(parts) == 2 or (len(parts) >= 3 and parts[2] == 'svc')
    print(parts[0] if internal else '')
    print(parts[1] if internal else '')
except ValueError as exc:
    sys.exit('Invalid Prometheus URL: ' + str(exc))
PY
    local -a parts=()
    mapfile -t parts <"$WORKDIR/prom-url"
    PROM_HOST=${parts[0]} PROM_PORT=${parts[1]}
    PROMETHEUS_SERVICE=${PROMETHEUS_SERVICE:-${parts[2]}}
    PROMETHEUS_NAMESPACE=${PROMETHEUS_NAMESPACE:-${parts[3]}}
    [[ -n $PROMETHEUS_SERVICE && -n $PROMETHEUS_NAMESPACE ]] ||
        die 'Use a Service DNS URL or set --prometheus-service and --prometheus-namespace.'
    dns_label prometheus-service "$PROMETHEUS_SERVICE"
    dns_label prometheus-namespace "$PROMETHEUS_NAMESPACE"
    k -n "$PROMETHEUS_NAMESPACE" get service "$PROMETHEUS_SERVICE" -o name >&2
    local -a cmd=(kubectl --context="$CONTEXT" --request-timeout=30s -n "$PROMETHEUS_NAMESPACE"
        port-forward --address=127.0.0.1 "service/$PROMETHEUS_SERVICE" ":$PROM_PORT")
    echo_action "${cmd[@]}"
    "${cmd[@]}" >"$WORKDIR/port-forward.log" 2>&1 &
    PF_PID=$!
    local deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        LOCAL_PORT=$(python3 - "$WORKDIR/port-forward.log" <<'PY'
import re, sys
m = re.search(r'Forwarding from 127\.0\.0\.1:(\d+)', open(sys.argv[1]).read())
print(m[1] if m else '')
PY
        )
        [[ -z $LOCAL_PORT ]] || break
        kill -0 "$PF_PID" 2>/dev/null || { cat "$WORKDIR/port-forward.log" >&2; die 'Prometheus port-forward failed.'; }
        sleep 0.2
    done
    [[ -n $LOCAL_PORT ]] || die 'Timed out waiting for Prometheus port-forward.'
    local probe
    probe=$(prom_query 'vector(1)') || die 'Prometheus test query failed through port-forward.'
    metric_value "$probe" >/dev/null || die 'Prometheus returned an invalid test response.'
    log OK 'Prometheus is reachable through port-forward (no test Pod was created).'
}

prom_query() {
    local response
    response=$(run curl --silent --show-error --fail --noproxy '*' \
        --connect-timeout 5 --max-time 15 \
        --connect-to "$PROM_HOST:$PROM_PORT:127.0.0.1:$LOCAL_PORT" \
        --get "${PROMETHEUS_URL%/}/api/v1/query" --data-urlencode "query=$1") || return 1
    jq -e '.status == "success" and (.data.result|type == "array")' <<<"$response" >/dev/null || {
        log ERROR "Prometheus query failed: $(jq -r '.error // "invalid response"' <<<"$response")"; return 1;
    }
    printf '%s\n' "$response"
}

metric_value() {
    jq -er 'if .data.resultType == "vector" and (.data.result|length) == 1 then
        .data.result[0].value[1] | tonumber | select(. >= 0 and . < 1e100)
        else error("expected one nonnegative finite vector sample") end' <<<"$1"
}

discover_metrics() {
    local response pairs metric_service metric_namespace selector ksm_selector
    metric_service=$(json_string "$SERVICE")
    response=$(prom_query "nginx_ingress_controller_requests{service=$metric_service} or nginx_ingress_controller_requests{exported_service=$metric_service}")
    pairs=$(jq -c --arg ns "$NAMESPACE" --arg svc "$SERVICE" '
        [.data.result[].metric | . as $m |
        (if has("exported_namespace") then "exported_namespace" else "namespace" end) as $n |
        (if has("exported_service") then "exported_service" else "service" end) as $s |
        select($m[$n] == $ns and $m[$s] == $svc) | [$n,$s]] | unique' <<<"$response")
    [[ $(jq 'length' <<<"$pairs") == 1 ]] ||
        die 'No unambiguous live ingress-nginx series for this Service. Send traffic, wait for scrapes, and verify service/namespace labels.'
    NAMESPACE_LABEL=$(jq -r '.[0][0]' <<<"$pairs")
    SERVICE_LABEL=$(jq -r '.[0][1]' <<<"$pairs")
    metric_namespace=$(json_string "$NAMESPACE")
    selector="nginx_ingress_controller_requests{$NAMESPACE_LABEL=$metric_namespace,$SERVICE_LABEL=$metric_service"
    if [[ -n $EXCLUDE_PATHS ]]; then
        jq -e --arg ns "$NAMESPACE" --arg svc "$SERVICE" --arg n "$NAMESPACE_LABEL" --arg s "$SERVICE_LABEL" '
            [.data.result[].metric | select(.[$n] == $ns and .[$s] == $svc)] |
            length > 0 and all(.[]; has("path"))' <<<"$response" >/dev/null ||
            die 'Real series lack a path label; path exclusions cannot work. Use --exclude-paths "" only if acceptable.'
        selector+=",path!~$(json_string "$EXCLUDE_PATHS")"
    fi
    selector+='}'
    QUERY="sum(increase(${selector}[2m]))"
    response=$(prom_query "$QUERY") || die 'Traffic query failed (check the Prometheus/RE2 exclusion regex).'
    metric_value "$response" >/dev/null || die 'Traffic query is empty/invalid; eligible series need at least two scrapes in 2m.'
    local dep_string
    dep_string=$(json_string "$DEPLOYMENT")
    response=$(prom_query "kube_deployment_spec_replicas{deployment=$dep_string} or kube_deployment_spec_replicas{exported_deployment=$dep_string}")
    pairs=$(jq -c --arg ns "$NAMESPACE" --arg dep "$DEPLOYMENT" '
        [.data.result[].metric | . as $m |
        (if has("exported_namespace") then "exported_namespace" else "namespace" end) as $n |
        (if has("exported_deployment") then "exported_deployment" else "deployment" end) as $d |
        select($m[$n] == $ns and $m[$d] == $dep) | [$n,$d]] | unique' <<<"$response")
    [[ $(jq 'length' <<<"$pairs") == 1 ]] ||
        die 'kube_deployment_spec_replicas is missing/ambiguous. Scrape kube-state-metrics to keep low-traffic, running Pods awake.'
    KSM_NAMESPACE_LABEL=$(jq -r '.[0][0]' <<<"$pairs")
    KSM_DEPLOYMENT_LABEL=$(jq -r '.[0][1]' <<<"$pairs")
    ksm_selector="kube_deployment_spec_replicas{$KSM_NAMESPACE_LABEL=$metric_namespace,$KSM_DEPLOYMENT_LABEL=$dep_string}"
    REPLICA_QUERY="max($ksm_selector)"
    KEEP_QUERY="$QUERY * on() ($REPLICA_QUERY > bool 0)"
    response=$(prom_query "$KEEP_QUERY")
    metric_value "$response" >/dev/null || die 'The keep-awake query must return one nonnegative value.'
    log OK "Detected request labels: $NAMESPACE_LABEL, $SERVICE_LABEL; exclusions validated by Prometheus."
}

check_scaling_conflicts() {
    local hpas objects
    hpas=$(k -n "$NAMESPACE" get hpa -o json)
    PENDING_HPAS=$(jq -c --arg d "$DEPLOYMENT" --argjson so "${SO_JSON:-null}" '
        [.items[] | select(.spec.scaleTargetRef.name == $d and
            .spec.scaleTargetRef.kind == "Deployment" and
            .spec.scaleTargetRef.apiVersion == "apps/v1") |
            select(all(.metadata.ownerReferences[]?; .uid != $so.metadata.uid))]' <<<"$hpas")
    if [[ $(jq 'length' <<<"$PENDING_HPAS") != 0 ]]; then
        log WARN "Conflicting HPA(s): $(jq -r 'map(.metadata.name)|join(", ")' <<<"$PENDING_HPAS")"
        [[ $REPLACE_HPA == true ]] ||
            die 'A plain HPA already targets this Deployment. KEDA needs its own HPA. Re-run with --replace-hpa to back up and replace it.'
        jq -e 'all(.[]; ((.metadata.ownerReferences // [])|length) == 0)' <<<"$PENDING_HPAS" >/dev/null ||
            die '--replace-hpa only replaces plain HPAs; another controller owns this HPA.'
    fi
    if [[ -n $CRD_JSON ]]; then
        objects=$(k -n "$NAMESPACE" get scaledobjects -o json)
        jq -e --arg d "$DEPLOYMENT" --arg name "$NAME" '
            all(.items[]; .metadata.name == $name or .spec.scaleTargetRef.name != $d)' <<<"$objects" >/dev/null ||
            die 'Another ScaledObject already targets this Deployment.'
    fi
}

ensure_keda() {
    if [[ -z $CRD_JSON ]]; then
        if [[ $APPLY != true ]]; then
            log INFO 'PLAN: install KEDA 2.x from kedacore/keda in namespace keda; wait for its operator.'
            INITIAL_SUPPORTED=true
            return
        fi
        h repo add kedacore https://kedacore.github.io/charts --force-update >&2
        h repo update kedacore >&2
        local chart_version=$KEDA_CHART_VERSION available
        if [[ -z $chart_version ]]; then
            available=$(h search repo kedacore/keda --versions -o json)
            chart_version=$(jq -er '[.[] | select(.name == "kedacore/keda" and
                (.app_version|test("^v?2\\.")))][0].version // empty' <<<"$available") ||
                die 'Could not resolve a KEDA 2.x chart; set --keda-chart-version.'
        else
            available=$(h show chart kedacore/keda --version "$chart_version")
            [[ $available =~ appVersion:[[:space:]]*[\"\']?v?2\. ]] || die 'The pinned chart must provide KEDA 2.x.'
        fi
        h upgrade --install keda kedacore/keda --namespace keda --create-namespace \
            --version "$chart_version" --wait --timeout 5m >&2
        k wait --for=condition=Established "crd/$CRD" --timeout=120s >&2
        CRD_JSON=$(k get crd "$CRD" -o json)
        if jq -e 'any(.spec.versions[]; .served == true and
            .schema.openAPIV3Schema.properties.spec.properties.initialCooldownPeriod != null)' \
            <<<"$CRD_JSON" >/dev/null; then INITIAL_SUPPORTED=true; fi
    fi
    local operators ns name
    operators=$(k get deployments -A -l app.kubernetes.io/name=keda-operator -o json)
    [[ $(jq '.items|length' <<<"$operators") != 0 ]] || die 'ScaledObject CRD exists, but no labelled KEDA operator Deployment was found.'
    while IFS=$'\t' read -r ns name; do
        k -n "$ns" rollout status "deployment/$name" --timeout=180s >&2
    done < <(jq -r '.items[]|[.metadata.namespace,.metadata.name]|@tsv' <<<"$operators")
}

render_scaledobject() {
    cat <<YAML
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: $NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/managed-by: sleep-mode
  annotations:
    sleepmode/deployment-uid: $(json_string "$DEP_UID")
    sleepmode/service: $(json_string "$SERVICE")
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: $DEPLOYMENT
  minReplicaCount: 0 # Allow the Deployment to sleep completely.
  maxReplicaCount: $MAX_REPLICAS # Captured original replicas, minimum 1, unless overridden.
  pollingInterval: $POLL_SECONDS # Seconds between KEDA's checks while asleep.
  cooldownPeriod: $((IDLE_MINUTES * 60)) # $IDLE_MINUTES minutes after the last active trigger.
YAML
    if [[ $INITIAL_SUPPORTED == true ]]; then
        printf '  initialCooldownPeriod: %s # Protect the first idle period after creation (KEDA >= 2.14).\n' "$((IDLE_MINUTES * 60))"
    fi
    cat <<YAML
  advanced:
    restoreToOriginalReplicaCount: false # disable restores our saved snapshot explicitly.
  triggers:
    - type: prometheus
      name: wake
      metricType: AverageValue
      metadata:
        serverAddress: $(json_string "$PROMETHEUS_URL")
        # 2m is a sliding, extrapolated request-count estimate, including 503s.
        query: $(json_string "$QUERY")
        threshold: "$THRESHOLD" # Estimated requests per pod per 2m for HPA scaling (default 50).
        activationThreshold: "$((WAKE_HITS - 1))" # Strictly greater than N-1; approximate $WAKE_HITS-hit wake.
        ignoreNullValues: "false" # Missing metrics are an error, not invented zero traffic.
    - type: prometheus
      name: keep-awake
      metricType: AverageValue
      metadata:
        serverAddress: $(json_string "$PROMETHEUS_URL")
        # Gate on desired replicas > 0 so even one request keeps RUNNING pods awake.
        query: $(json_string "$KEEP_QUERY")
        threshold: "$THRESHOLD" # Same per-pod target; HPA takes the maximum, not the sum.
        activationThreshold: "0" # Any measured traffic resets the running workload's cooldown.
        ignoreNullValues: "false" # Missing kube-state-metrics must not look like zero activity.
YAML
}

sanitize_hpas() {
    jq -c 'map(del(.status,.metadata.uid,.metadata.resourceVersion,.metadata.generation,
        .metadata.creationTimestamp,.metadata.managedFields,.metadata.selfLink,
        .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]))' <<<"$1"
}

save_state() {
    local pending_clean combined current_rv annotation_value state_file
    pending_clean=$(sanitize_hpas "$PENDING_HPAS")
    # Existing backups are immutable. A same-name replacement must match its backup.
    combined=$(jq -cn --argjson old "$BACKED_HPAS" --argjson new "$pending_clean" '
        reduce $new[] as $item ($old;
            if any(.[]; .metadata.name == $item.metadata.name and . != $item) then
                error("HPA changed since its original backup; refusing to overwrite recovery state")
            elif any(.[]; .metadata.name == $item.metadata.name) then . else . + [$item] end)')
    mkdir -p -- "$BACKUP_DIR"
    local key
    key=$(python3 - "$CONTEXT" "$NAMESPACE" "$DEP_UID" <<'PY'
import hashlib, sys
print(hashlib.sha256('\0'.join(sys.argv[1:]).encode()).hexdigest()[:16])
PY
    )
    # Write a private, atomic, durable-on-disk copy before deleting ANY HPA.
    jq -n --argjson items "$combined" '{apiVersion:"v1",kind:"List",items:$items}' >"$WORKDIR/hpas.json"
    cp -- "$WORKDIR/hpas.json" "$BACKUP_DIR/$NAME-$key-hpas.json.tmp"
    mv -- "$BACKUP_DIR/$NAME-$key-hpas.json.tmp" "$BACKUP_DIR/$NAME-$key-hpas.json"
    log INFO "HPA backup file: $BACKUP_DIR/$NAME-$key-hpas.json"
    state_file="$WORKDIR/state.json"
    jq -n --arg n "$STATE_NAME" --arg ns "$NAMESPACE" --arg uid "$DEP_UID" \
        --arg original "$ORIGINAL_REPLICAS" --arg hpas "$combined" '
        {apiVersion:"v1",kind:"ConfigMap",metadata:{name:$n,namespace:$ns,
        labels:{"app.kubernetes.io/managed-by":"sleep-mode"}},data:{
        "deployment-uid":$uid,"original-replicas":$original,"hpas.json":$hpas}}' >"$state_file"
    (( $(wc -c <"$state_file") < 800000 )) || die 'HPA backups are too large for the recovery ConfigMap.'
    if [[ -z $STATE_JSON ]]; then
        k create -f "$state_file" >&2
    else
        # A resourceVersion guard prevents clobbering concurrent recovery changes.
        jq --arg rv "$(jq -r '.metadata.resourceVersion' <<<"$STATE_JSON")" \
            '.metadata.resourceVersion=$rv' "$state_file" >"$WORKDIR/state-replace.json"
        k replace -f "$WORKDIR/state-replace.json" >&2
    fi
    ENABLE_DIRTY=true
    annotation_value=$(jq -r --arg a "$ANNOTATION" '.metadata.annotations[$a] // empty' <<<"$DEP_JSON")
    if [[ -z $annotation_value ]]; then
        # Refresh the Deployment to avoid overwriting a concurrently added annotation.
        DEP_JSON=$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o json)
        [[ $(jq -r '.metadata.uid' <<<"$DEP_JSON") == "$DEP_UID" ]] || die 'Deployment was recreated during enable.'
        current_rv=$(jq -r '.metadata.resourceVersion' <<<"$DEP_JSON")
        annotation_value=$(jq -r --arg a "$ANNOTATION" '.metadata.annotations[$a] // empty' <<<"$DEP_JSON")
        [[ -z $annotation_value || $annotation_value == "$ORIGINAL_REPLICAS" ]] || die 'Original replica annotation changed concurrently.'
        k -n "$NAMESPACE" annotate deployment "$DEPLOYMENT" "$ANNOTATION=$ORIGINAL_REPLICAS" \
            --resource-version="$current_rv" >&2
    fi
    local name uid live
    while IFS=$'\t' read -r name uid; do
        live=$(k -n "$NAMESPACE" get hpa "$name" --ignore-not-found -o json)
        [[ -n $live ]] || continue
        [[ $(jq -r '.metadata.uid' <<<"$live") == "$uid" ]] || die "HPA $name was replaced during enable."
        k -n "$NAMESPACE" delete hpa "$name" --wait=true --timeout=60s >&2
    done < <(jq -r '.[]|[.metadata.name,.metadata.uid]|@tsv' <<<"$PENDING_HPAS")
}

enable_sleep() {
    verify_service
    check_scaling_conflicts
    start_prometheus
    discover_metrics
    ensure_keda
    render_scaledobject >"$WORKDIR/scaledobject.yaml"
    cat "$WORKDIR/scaledobject.yaml"
    if [[ $APPLY == true ]]; then
        save_state
        k apply -f "$WORKDIR/scaledobject.yaml" >&2
        k -n "$NAMESPACE" wait --for=condition=Ready "scaledobject/$NAME" --timeout=180s >&2
        local live hpa_name
        live=$(k -n "$NAMESPACE" get scaledobject "$NAME" -o json)
        local state_patch
        state_patch=$(jq -cn --arg uid "$(jq -r '.metadata.uid' <<<"$live")" '{data:{"scaledobject-uid":$uid}}')
        k -n "$NAMESPACE" patch configmap "$STATE_NAME" --type=merge -p "$state_patch" >&2
        hpa_name=$(jq -er '.status.hpaName // empty' <<<"$live") || die 'KEDA has not reported its HPA name.'
        k -n "$NAMESPACE" label hpa "$hpa_name" app.kubernetes.io/managed-by=sleep-mode --overwrite >&2
        ENABLE_DIRTY=false
        log OK "Enabled ScaledObject $NAMESPACE/$NAME; recovery ConfigMap $STATE_NAME; original replicas $ORIGINAL_REPLICAS."
    else
        log INFO "PLAN ONLY: save replicas=$ORIGINAL_REPLICAS, persist HPA backups, replace approved HPAs, and apply $NAME."
    fi
    log INFO "Sleep: no measured eligible traffic for about $IDLE_MINUTES minutes plus the 2m window and scrape/poll delays."
    log INFO "Wake: 2m request estimate > $((WAKE_HITS - 1)); cold start ~ scrape delay + up to 15s polling + image pull + readiness."
    log WARN 'First requests may receive 503; increase() and scrape/gauge lag make the hit threshold approximate.'
}

disable_sleep() {
    local saved_annotation
    saved_annotation=$(jq -r --arg a "$ANNOTATION" '.metadata.annotations[$a] // empty' <<<"$DEP_JSON")
    if [[ -z $SO_JSON && -z $STATE_JSON && -z $saved_annotation ]]; then
        log OK 'Already disabled; no resources or replicas changed.'
        return
    fi
    if [[ $APPLY != true ]]; then
        log INFO "PLAN: delete ScaledObject $NAME, restore replicas=$ORIGINAL_REPLICAS, restore saved HPAs, remove annotation/state."
        jq -n --arg ns "$NAMESPACE" --arg name "$DEPLOYMENT" --argjson r "$ORIGINAL_REPLICAS" \
            '{apiVersion:"apps/v1",kind:"Deployment",metadata:{namespace:$ns,name:$name},spec:{replicas:$r}}'
        printf '\n---\n'
        jq -n --argjson items "$BACKED_HPAS" '{apiVersion:"v1",kind:"List",items:$items}'
        return
    fi
    local so_uid='' leftovers name existing desired
    if [[ -n $STATE_JSON ]]; then
        so_uid=$(jq -r '.data["scaledobject-uid"] // empty' <<<"$STATE_JSON")
    fi
    if [[ -n $SO_JSON ]]; then
        so_uid=$(jq -r '.metadata.uid' <<<"$SO_JSON")
        k -n "$NAMESPACE" delete scaledobject "$NAME" --ignore-not-found --wait=true --timeout=120s >&2
    fi
    # Wait for/delete only HPAs owned by this exact ScaledObject, before restoring originals.
    if [[ -n $so_uid ]]; then
        leftovers=$(k -n "$NAMESPACE" get hpa -o json)
        while IFS= read -r name; do
            k -n "$NAMESPACE" delete hpa "$name" --ignore-not-found --wait=true --timeout=60s >&2
        done < <(jq -r --arg uid "$so_uid" '.items[] |
            select(any(.metadata.ownerReferences[]?; .uid == $uid)) | .metadata.name' <<<"$leftovers")
    fi
    k -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas="$ORIGINAL_REPLICAS" >&2
    local count i
    count=$(jq 'length' <<<"$BACKED_HPAS")
    for ((i=0; i<count; i++)); do
        desired=$(jq -c --argjson i "$i" '.[$i]' <<<"$BACKED_HPAS")
        name=$(jq -r '.metadata.name' <<<"$desired")
        existing=$(k -n "$NAMESPACE" get hpa "$name" --ignore-not-found -o json)
        if [[ -n $existing ]]; then
            existing=$(sanitize_hpas "[$existing]")
            jq -e --argjson wanted "$desired" '.[0] == $wanted' <<<"$existing" >/dev/null ||
                die "HPA $name already exists with different settings; recovery state retained."
        else
            printf '%s\n' "$desired" >"$WORKDIR/hpa-restore.json"
            k create -f "$WORKDIR/hpa-restore.json" >&2
        fi
    done
    # Remove recovery information only after every restore step succeeded.
    if [[ -n $saved_annotation ]]; then
        k -n "$NAMESPACE" annotate deployment "$DEPLOYMENT" "$ANNOTATION-" >&2
    fi
    if [[ -n $STATE_JSON ]]; then
        k -n "$NAMESPACE" delete configmap "$STATE_NAME" --ignore-not-found >&2
    fi
    log OK "Disabled; restored replicas=$ORIGINAL_REPLICAS and $count HPA(s). KEDA and local backup files were retained."
}

load_live_queries() {
    [[ -n $SO_JSON ]] || die 'Sleep mode is not enabled for this Deployment.'
    QUERY=$(jq -er '.spec.triggers[]|select(.name=="wake")|.metadata.query' <<<"$SO_JSON")
    KEEP_QUERY=$(jq -er '.spec.triggers[]|select(.name=="keep-awake")|.metadata.query' <<<"$SO_JSON")
    # Read configured queries/thresholds instead of the command-line defaults.
    WAKE_HITS=$(jq -er '(.spec.triggers[]|select(.name=="wake")|.metadata.activationThreshold|tonumber)+1' <<<"$SO_JSON")
    REPLICA_QUERY=${KEEP_QUERY#*' * on() ('}
    REPLICA_QUERY=${REPLICA_QUERY%' > bool 0)'}
}

show_status() {
    if [[ -z $SO_JSON ]]; then
        log INFO "Sleep mode disabled; current desired replicas: $(jq -r '.spec.replicas // 1' <<<"$DEP_JSON")."
        [[ -z $STATE_JSON ]] || log WARN "Recovery state still exists in ConfigMap $STATE_NAME; run disable --apply to finish."
        return
    fi
    load_live_queries
    jq -r '["Ready", "Active"][] as $type |
        ($type + "=" + ([.status.conditions[]? | select(.type==$type) | .status][0] // "Unknown"))' <<<"$SO_JSON"
    jq -r '"Replicas: desired=\(.spec.replicas // 1), actual=\(.status.replicas // 0), ready=\(.status.readyReplicas // 0)"' <<<"$DEP_JSON"
    if [[ -n $STATE_JSON ]] && jq -e '.data["test-restore.json"] != null' <<<"$STATE_JSON" >/dev/null; then
        log WARN "Interrupted test: recovery patch retained in ConfigMap $STATE_NAME."
    fi
    start_prometheus
    local response value keep_value replicas cooldown remaining last
    response=$(prom_query "$QUERY")
    value=$(metric_value "$response") || die 'Live request metric is absent/invalid; no reliable idle/wake estimate.'
    response=$(prom_query "$KEEP_QUERY")
    keep_value=$(metric_value "$response") || die 'Live keep-awake metric is absent/invalid.'
    printf 'Estimated eligible requests in last 2m: %s\nKeep-awake value: %s\n' "$value" "$keep_value"
    replicas=$(jq -r '.spec.replicas // 1' <<<"$DEP_JSON")
    if (( replicas == 0 )); then
        python3 - "$value" "$WAKE_HITS" <<'PY'
import math, sys
value, hits = map(float, sys.argv[1:])
print(f'Approximate additional hits to wake: {max(0, math.floor(hits - 1 - value) + 1)} '
      '(within the sliding 2m window; scrape estimates can differ).')
PY
    elif python3 - "$value" "$keep_value" "$WAKE_HITS" <<'PY'
import sys
v, k, h = map(float, sys.argv[1:])
sys.exit(0 if v > h - 1 or k > 0 else 1)
PY
    then
        cooldown=$(jq -r '.spec.cooldownPeriod // 300' <<<"$SO_JSON")
        printf 'Traffic is active; no sleep countdown yet. After traffic ends: roughly %ss + up to 2m + scrape/poll delay.\n' "$cooldown"
    else
        last=$(jq -r '.status.lastActiveTime // .metadata.creationTimestamp' <<<"$SO_JSON")
        remaining=$(python3 - "$last" "$SO_JSON" <<'PY'
import datetime, json, sys, time
t = datetime.datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00')).timestamp()
so = json.loads(sys.argv[2])
deadline = t + so['spec'].get('cooldownPeriod', 300)
created = datetime.datetime.fromisoformat(so['metadata']['creationTimestamp'].replace('Z', '+00:00')).timestamp()
deadline = max(deadline, created + so['spec'].get('initialCooldownPeriod', 0))
print(max(0, int(deadline - time.time() + 0.999)))
PY
        )
        printf 'Approximate time until sleep: %ss, plus polling/reconciliation delay (from KEDA lastActiveTime).\n' "$remaining"
    fi
}

detect_test_url() {
    local ingresses classes
    ingresses=$(k -n "$NAMESPACE" get ingress -o json)
    classes=$(k get ingressclass -o json)
    python3 - "$SERVICE" "$TEST_URL" "$ingresses" "$classes" <<'PY'
import json, sys, urllib.parse
svc, override = sys.argv[1:3]
ingresses, classes = map(json.loads, sys.argv[3:])
nginx = {c['metadata']['name'] for c in classes['items']
         if c['spec']['controller'] == 'k8s.io/ingress-nginx'}
routes = set()
for ing in ingresses['items']:
    cls = ing['spec'].get('ingressClassName') or ing['metadata'].get('annotations', {}).get('kubernetes.io/ingress.class')
    if cls not in nginx:
        continue
    tls = {host for entry in ing['spec'].get('tls', []) for host in entry.get('hosts', [])}
    for rule in ing['spec'].get('rules', []):
        host = rule.get('host', '')
        if not host or '*' in host:
            continue
        for p in rule.get('http', {}).get('paths', []):
            if p.get('backend', {}).get('service', {}).get('name') == svc:
                routes.add(('https' if host in tls else 'http', host, p.get('path') or '/', p.get('pathType')))
if override:
    u = urllib.parse.urlsplit(override)
    if (u.scheme not in ('http', 'https') or u.username or u.password or u.fragment or u.query or
            any(ord(c) < 32 for c in override)):
        sys.exit('test-url must be a credential-free HTTP(S) URL without a query or fragment')
    matches = []
    for scheme, host, path, kind in routes:
        prefix = (u.path or '/').rstrip('/') or '/'
        allowed = kind == 'ImplementationSpecific' or (kind == 'Exact' and prefix == path.rstrip('/')) or (
            kind == 'Prefix' and (path == '/' or prefix == path.rstrip('/') or prefix.startswith(path.rstrip('/') + '/')))
        if u.hostname == host and u.scheme == scheme and allowed:
            matches.append((host, path))
    if not matches:
        sys.exit('test-url must match a host/scheme/route on an ingress-nginx Ingress for this Service')
    print(override)
elif len(routes) == 1:
    scheme, host, path, kind = next(iter(routes))
    if kind not in ('Exact', 'Prefix') or not path.startswith('/'):
        sys.exit('Regex/ImplementationSpecific routes require --test-url with a safe concrete GET path')
    print(scheme + '://' + host + path)
else:
    sys.exit('No unique ingress-nginx host/path for this Service; use --test-url')
PY
}

test_sleep() {
    verify_service
    load_live_queries
    TEST_URL=$(detect_test_url) || die 'Could not determine a safe test ingress URL.'
    if [[ $APPLY != true ]]; then
        log INFO "PLAN ONLY: cooldown=60s; wait <=5m for zero Pods; send $WAKE_HITS GETs to $TEST_URL; measure wake/readiness; restore settings."
        printf 'apiVersion: keda.sh/v1alpha1\nkind: ScaledObject\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  cooldownPeriod: 60 # Temporary one-minute test cooldown.\n' "$NAME" "$NAMESPACE"
        [[ $INITIAL_SUPPORTED != true ]] || printf '  initialCooldownPeriod: 0 # Temporarily remove initial creation protection.\n'
        return
    fi
    start_prometheus
    local response value patch_file patch_json deadline live replicas start_time scaled_time='' ready_time=''
    response=$(prom_query "$QUERY"); metric_value "$response" >/dev/null
    # A path may be excluded by an Ingress template path rather than the literal URL.
    log WARN "Test sends $WAKE_HITS GET requests to $TEST_URL; choose an idempotent endpoint and stop other traffic."
    TEST_UID=$(jq -er '.metadata.uid' <<<"$SO_JSON")
    mkdir -p -- "$BACKUP_DIR"
    RESTORE_FILE="$BACKUP_DIR/$NAME-test-restore-$(date -u +'%Y%m%dT%H%M%SZ')-$$.json"
    jq -n --arg uid "$TEST_UID" --argjson so "$SO_JSON" --argjson initial "$INITIAL_SUPPORTED" '
        [{op:"test",path:"/metadata/uid",value:$uid},
         {op:"test",path:"/spec/cooldownPeriod",value:60},
         {op:"add",path:"/spec/cooldownPeriod",value:($so.spec.cooldownPeriod // 300)}] +
        (if $initial then [{op:"test",path:"/spec/initialCooldownPeriod",value:0}] +
         (if $so.spec|has("initialCooldownPeriod") then
            [{op:"add",path:"/spec/initialCooldownPeriod",value:$so.spec.initialCooldownPeriod}]
          else [{op:"remove",path:"/spec/initialCooldownPeriod"}] end) else [] end)' >"$RESTORE_FILE"
    [[ -n $STATE_JSON ]] || die 'Persistent state is missing; re-run enable before testing.'
    patch_json=$(jq -cn --arg patch "$(cat "$RESTORE_FILE")" '{data:{"test-restore.json":$patch}}')
    k -n "$NAMESPACE" patch configmap "$STATE_NAME" --type=merge -p "$patch_json" >&2
    patch_file="$WORKDIR/test-patch.json"
    jq -n --arg uid "$TEST_UID" --argjson so "$SO_JSON" --argjson initial "$INITIAL_SUPPORTED" '
        [{op:"test",path:"/metadata/uid",value:$uid},
         {op:"test",path:"/spec/cooldownPeriod",value:($so.spec.cooldownPeriod // 300)},
         {op:"add",path:"/spec/cooldownPeriod",value:60}] +
         (if $initial then [{op:"add",path:"/spec/initialCooldownPeriod",value:0}] else [] end)' >"$patch_file"
    # Arm BEFORE the mutation so signals or uncertain API responses still attempt recovery.
    TEST_PATCHED=true
    k -n "$NAMESPACE" patch scaledobject "$NAME" --type=json --patch-file="$patch_file" >&2
    deadline=$((SECONDS + 300))
    log INFO 'Waiting up to 5 minutes for desired AND actual replicas to reach zero (also allowing the 2m metric window to drain).'
    while :; do
        live=$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o json)
        if jq -e '.spec.replicas == 0 and (.status.replicas // 0) == 0' <<<"$live" >/dev/null; then
            response=$(prom_query "$REPLICA_QUERY"); value=$(metric_value "$response")
            # Wait for the replica gauge to catch up, so the keep-awake gate is closed.
            if python3 - "$value" <<'PY'
import sys
sys.exit(0 if float(sys.argv[1]) == 0 else 1)
PY
            then break; fi
        fi
        (( SECONDS < deadline )) || die 'Sleep timed out: inspect traffic, excluded paths, KEDA conditions and metric availability.'
        sleep 3
    done
    # Verify that the existing aggregate remains usable. This cannot seed a
    # never-before-seen 503 series; the README explains that first-sample limit.
    response=$(prom_query "$QUERY"); value=$(metric_value "$response")
    log INFO "Asleep; baseline 2m estimate=$value. Sending exactly $WAKE_HITS requests, with no automatic retries."
    start_time=$SECONDS
    local i code
    for ((i=1; i<=WAKE_HITS; i++)); do
        if code=$(run curl --silent --show-error --connect-timeout 5 --max-time 10 \
            --output /dev/null --write-out '%{http_code}' "$TEST_URL"); then
            log INFO "Wake hit $i/$WAKE_HITS: HTTP $code"
        else
            log ERROR "Wake hit $i/$WAKE_HITS: HTTP ${code:-000} (transport/TLS failure)."
            die 'An ingress request failed at the transport layer; this is not a valid wake test.'
        fi
    done
    deadline=$((SECONDS + 300))
    while :; do
        live=$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o json)
        replicas=$(jq -r '.spec.replicas // 0' <<<"$live")
        if (( replicas > 0 )) && [[ -z $scaled_time ]]; then
            scaled_time=$((SECONDS - start_time))
            log OK "Deployment replicas > 0 after ${scaled_time}s."
        fi
        if (( replicas > 0 )) && jq -e '(.status.readyReplicas // 0) > 0 and
            (.status.observedGeneration // 0) >= .metadata.generation' <<<"$live" >/dev/null; then
            ready_time=$((SECONDS - start_time))
            break
        fi
        (( SECONDS < deadline )) || die 'Wake timed out: 503 series may be missing, freshly created counters may hide first hits, or Pods may not be Ready.'
        sleep 2
    done
    # No readiness curl is sent: it would alter the experiment's exact request count.
    log OK "TEST PASSED: replicas > 0 after ${scaled_time}s; at least one Deployment Pod Ready after ${ready_time}s (measured from first hit)."
    restore_test_settings
}

main() {
    umask 077
    parse_args "$@"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'log ERROR "Command failed at line $LINENO (exit $?)."' ERR
    common_preflight
    case "$SUBCOMMAND" in
        enable) enable_sleep ;;
        disable) disable_sleep ;;
        status) show_status ;;
        test) test_sleep ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
