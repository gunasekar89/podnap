# podnap

💤 Sleep idle Kubernetes Deployments and wake them from ingress traffic. A KEDA + ingress-nginx setup for dev, QA and preview environments, with dry-run enabled by default.

**Serving → idle ~30 minutes → 0 Pods → ~3 hits → wake**

## Assumptions / prerequisites

- A dedicated Service selects the Deployment; its traffic passes through ingress-nginx. Prometheus continues scraping `nginx_ingress_controller_requests` while the backend is at zero, **including 503 requests**.
- Prometheus also scrapes **kube-state-metrics** (`kube_deployment_spec_replicas`). This lets one request keep running Pods awake while requiring approximately three hits to wake sleeping Pods. A single trigger with activation threshold `2` would incorrectly ignore isolated requests when calculating idle time.
- The Prometheus endpoint is unauthenticated, reachable through a Kubernetes Service and accessible from KEDA. Use 15–30s scrapes, at least two samples per time series in 2m, and deduplicated HA data. TLS verification stays enabled.
- Install Bash 4+, kubectl 1.27+, Helm 3, jq 1.6+, curl and Python 3. KEDA 2.x is supported; 2.14+ is recommended for initial cooldown protection. Your identity needs resource read/write and port-forward permissions; initial KEDA installation also needs cluster-scoped permissions. macOS's bundled Bash 3 is too old.
- No other scaler/GitOps process overwrites these resources. Run one mutation per Deployment at a time. For `test`, use a safe GET endpoint reachable from your workstation, in a non-production namespace.

## Quick start

```bash
chmod +x sleep-mode.sh

# Preview: confirms context, checks real metrics, prints YAML, changes nothing.
./sleep-mode.sh enable -n dev -d orders-api \
  --prometheus-url http://prometheus.monitoring:9090

# Enable. Add --replace-hpa if replacing a plain HPA is intended.
./sleep-mode.sh enable -n dev -d orders-api \
  --prometheus-url http://prometheus.monitoring:9090 --apply --yes

# Stored Prometheus URL/queries are reused by status and test.
./sleep-mode.sh status -n dev -d orders-api --apply --yes
./sleep-mode.sh test -n dev -d orders-api --apply --yes
./sleep-mode.sh disable -n dev -d orders-api --apply --yes
```

`--apply --yes` skips the context prompt. `status` always remains read-only. Dry-run uses a local port-forward without creating test Pods; dry-run `test` sends no requests. Logs and echoed kubectl/Helm commands go to stderr; `enable` writes YAML to stdout. Use `NO_COLOR=1` to disable terminal colors.

| Option | Default / environment fallback |
| --- | --- |
| `--namespace`, `--deployment` | Required / `NAMESPACE`, `DEPLOYMENT` |
| `--service` | Deployment name / `SERVICE` |
| `--prometheus-url` | Required on first enable / `PROMETHEUS_URL` |
| `--idle-minutes`, `--wake-hits` | `30`, `3` / `IDLE_MINUTES`, `WAKE_HITS` |
| `--max-replicas` | Original desired replicas, minimum 1 / `MAX_REPLICAS` |
| `--threshold` | `50` requests per pod per 2m / `THRESHOLD` |
| `--exclude-paths` | `/healthz\|/readyz\|/livez\|/health\|/ping` / `EXCLUDE_PATHS` |

See `./sleep-mode.sh --help` for every flag/env fallback, including `--replace-hpa`, `--test-url`, `--backup-dir`, `--ingress-namespace`, Service port-forward overrides and `--keda-chart-version`. Boolean environment values are `true`/`false`; CLI flags override them.

## Behavior and recovery

The script discovers actual metric labels (`namespace` vs `exported_namespace`, and Service labels), validates exclusions with Prometheus, and installs `kedacore/keda` in `keda` **only when its CRD is missing**. Existing installations are never upgraded. Supply a chart version for reproducible installation.

It captures `sleepmode/original-replicas` once, saves approved HPA replacements both to a private local file and a recovery ConfigMap, and creates/updates a ScaledObject with 15s polling and two Prometheus triggers. Created scaling/recovery resources are labelled `app.kubernetes.io/managed-by=sleep-mode`; existing Helm/workload ownership labels are preserved.

Disable deletes the ScaledObject and its HPA, restores original replicas/HPAs, and removes recovery state. Running it twice is safe. KEDA and local backup files remain. A failed enable retains recovery state for retry/disable.

`test --apply` temporarily changes cooldown to 60s, waits up to 5m for zero replicas, sends exactly `WAKE_HITS` requests through the detected Ingress, reports their HTTP codes and measures time to replicas > 0 and a Ready Pod. It restores cooldown on EXIT/INT/TERM. Recovery patches also survive in a ConfigMap for machine loss/SIGKILL. See [operations and manual recovery](docs/OPERATIONS.md).

`kube-system`, `keda` and ingress namespaces are protected. Production-looking contexts need `--force`; **test refuses production-looking contexts/namespaces/environment labels even with force**. Names alone cannot establish that a cluster is non-production.

## Known trade-offs

- First requests during cold start get **503s**. Use client retries, a custom error page, or the [KEDA HTTP add-on](https://kedacore.github.io/http-add-on/), which holds requests in a proxy.
- External uptime monitors count as traffic. Exclude their paths or the Service may never sleep. The metric's path label can be an **Ingress route template**, so a single `/` route cannot distinguish `/health` from real traffic.
- Cold start ≈ **scrape/ingestion delay + polling interval + image pull + scheduling/readiness**. This is unsuitable for latency-critical production.
- Scaling to zero saves compute money only if **cluster autoscaler or Karpenter removes empty nodes**.
- The requested `[2m]` window plus 30m cooldown means sleep is generally **about 32m** after the final request. Prometheus `increase()` extrapolates, so waking on exactly the third HTTP request is not guaranteed. New 503 series can miss first increments; replica-gauge lag can wake earlier. Exact semantics require a request-aware, stateful scaler/proxy.
- Empty metrics cause an error rather than invented zero traffic. Telemetry outages can block sleep or wake. Validate your controller's zero-backend metrics with `test`.

## Validation

```bash
chmod +x sleep-mode.sh tests/mock_cluster.py
bash -n sleep-mode.sh
shellcheck --severity=style sleep-mode.sh
python3 -m pip install PyYAML  # Test-only dependency.
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Tests use offline CLI doubles and never access a cluster. Run the included `test --apply` on your non-production cluster for live verification. [Sample YAML](scaledobject.example.yaml) uses default values with one assumed original replica; generate your real configuration with the script.

Details and primary documentation links: [OPERATIONS.md](docs/OPERATIONS.md).
