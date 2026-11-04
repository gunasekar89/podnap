# Sleep Mode for Pods

Scale an ingress-nginx-backed Deployment to zero with KEDA and wake it from ingress request metrics. **Dry-run is the default.** `--apply` is required for changes and for sending test traffic.

## Cluster assumptions and prerequisites

- A dedicated Service selects this Deployment's Pods. Its public traffic passes through a `networking.k8s.io/v1` Ingress handled by ingress-nginx. Direct Service traffic, queues and background work are outside this policy.
- Prometheus scrapes `nginx_ingress_controller_requests`, including requests returning **503 when the backend has no endpoints**. The selected time series must remain exposed while asleep. Validate this with `test`; this behavior depends on your controller/configuration.
- Prometheus also scrapes **kube-state-metrics** (`kube_deployment_spec_replicas`). This extra gauge separates “any traffic keeps running Pods awake” from “approximately three hits wake sleeping Pods.” With only the requested wake trigger, isolated requests would not reset KEDA's idle timer.
- The Prometheus query endpoint is reachable without authentication through a Kubernetes Service, both by port-forward and from KEDA. TLS certificates must be trusted. The endpoint supplies deduplicated data: duplicate HA scrapes otherwise inflate counts. Use scrape intervals of about 15–30 seconds, with at least two samples per series in the 2-minute window.
- Bash 4+, kubectl 1.27+ (major 1), Helm 3, jq 1.6+, curl and Python 3 are installed. macOS's bundled Bash 3.2 is too old. KEDA 2.x is supported; **2.14+ is recommended** for the initial cooldown guard. Choose a chart compatible with your Kubernetes server version.
- Your identity can read namespaces, controller Pods and operator Deployments cluster-wide; read workload/Ingress/HPA resources; port-forward Prometheus; and, on apply, manage Deployments' scaling/annotations, ScaledObjects, HPAs and recovery ConfigMaps. Installing KEDA additionally requires cluster-scoped Helm/CRD/RBAC permissions and chart/image network access.
- No GitOps controller, scheduled scaler or other automation overwrites these resources. Run only one mutation at a time per Deployment. `test` uses a safe, idempotent GET endpoint reachable from your workstation; stop other traffic during that test.

## Use

```bash
chmod +x sleep-mode.sh

# Preview YAML and preflight the real metrics. Confirm the displayed context.
./sleep-mode.sh enable -n dev -d orders-api \
  --prometheus-url http://prometheus.monitoring:9090

# Enable; add --replace-hpa only to replace an existing plain HPA.
./sleep-mode.sh enable -n dev -d orders-api \
  --prometheus-url http://prometheus.monitoring:9090 --apply --yes

# These commands reuse the Prometheus URL and queries stored on the ScaledObject.
./sleep-mode.sh status -n dev -d orders-api --apply --yes
./sleep-mode.sh test -n dev -d orders-api --apply --yes
./sleep-mode.sh disable -n dev -d orders-api --apply --yes
```

`status` is read-only even with `--apply`. Here that flag, together with `--yes`, permits unattended context confirmation. Dry-run still runs read-only preflights and a local port-forward, but creates no Pods, patches no resources, installs nothing and sends no ingress test requests. Logs/echoed kubectl and Helm commands go to stderr; `enable` emits ScaledObject YAML to stdout. Color is enabled on terminals; set `NO_COLOR=1` to disable it.

All flags have uppercase environment equivalents, for example `NAMESPACE`, `DEPLOYMENT`, `PROMETHEUS_URL`, `IDLE_MINUTES`, `WAKE_HITS`, `MAX_REPLICAS`, `EXCLUDE_PATHS`, `APPLY`, `YES`, `FORCE`. See `./sleep-mode.sh --help` for all options. Booleans accept `true`/`false`. `DRY_RUN` overrides `APPLY` if both are set; command-line mode flags win in their supplied order.

| Setting | Default |
| --- | --- |
| Service | Deployment name |
| Idle cooldown | 30 minutes |
| Wake window / target | 2 minutes / approximately 3 hits |
| HPA target | 50 estimated requests per pod per 2 minutes (`--threshold`) |
| Maximum replicas | Original desired replicas, minimum 1; existing maximum retained on re-enable |
| Excluded ingress **path label** values | `/healthz\|/readyz\|/livez\|/health\|/ping` |
| KEDA polling | 15 seconds |
| Local HPA backup directory | `./sleep-mode-backups` |

Prometheus Service DNS examples: `http://prometheus.monitoring:9090` and `http://prometheus-server.monitoring.svc:80`. A reverse proxy/custom hostname needs `--prometheus-service` and `--prometheus-namespace`. The URL port must name a port exposed by that Service. Path prefixes and HTTPS/SNI are preserved. Port-forward success does not prove KEDA's network access: apply also waits for the ScaledObject's Ready condition.

Namespaces `kube-system`, `keda` and discovered ingress controller namespaces are protected. Use `--ingress-namespace` for custom controller labels/namespaces. Context names containing `prod|prd|live` are refused unless `--force` is given. **`test` never accepts production-looking contexts, namespace names or environment labels, even with `--force`.** Name checks cannot establish that an arbitrarily named cluster is non-production.

## How it works

**Serving → idle ~30 minutes → 0 Pods → ~3 hits → wake**

1. Discover the real Service/namespace metric labels, preferring `exported_service`/`exported_namespace` when Prometheus renamed colliding labels. Reject missing/ambiguous series. Verify the path label and validate the exclusion regex by querying Prometheus itself.
2. Install `kedacore/keda` in `keda` **only if the ScaledObject CRD is absent**, then wait for the operator. Existing installations are never upgraded. An unpinned install resolves the latest available stable KEDA **2.x** chart; supply `--keda-chart-version` for reproducible installation. Helm retains ownership of its shared infrastructure.
3. Capture `sleepmode/original-replicas` once. Save plain HPA backups locally as private JSON files and in a labelled recovery ConfigMap **before deleting HPAs** with `--replace-hpa`.
4. Create/update a labelled ScaledObject with two Prometheus triggers. The `wake` trigger uses the requested `sum(increase(...[2m]))`, threshold `50` and activation threshold `WAKE_HITS - 1`. The `keep-awake` trigger multiplies that query by a `desired replicas > 0` gauge and activates on any positive traffic. The HPA uses the maximum recommendation from the triggers, not their sum. New ScaledObjects also receive the configured initial cooldown when the installed CRD supports it.
5. Disable deletes this ScaledObject and its HPA, restores the captured replicas and backed-up HPAs, then removes the annotation/recovery ConfigMap. Repeated disable is a no-op. KEDA and local backup files are retained. Restored HPAs resume their own scaling policy immediately.

Created ScaledObjects, recovery ConfigMaps and KEDA-generated HPAs carry `app.kubernetes.io/managed-by=sleep-mode`. Existing Deployment/Service ownership labels and Helm-owned KEDA infrastructure keep their owners. Deployment UIDs and recovery resource ownership are checked to prevent restoring an old workload's state onto a recreated Deployment.

### Measurement limits

- **This is an approximate idle/wake policy.** The specified 2-minute sliding window plus a 30-minute cooldown generally means sleep about **32 minutes after the final observed request**, plus scrape, reconciliation and termination delays. It cannot promise exactly 30 wall-clock minutes. KEDA uses its last active trigger timestamp, not a timestamp of the final HTTP request.
- `increase()` extrapolates between scrapes and can return fractions. Strict activation `value > WAKE_HITS - 1` therefore cannot guarantee waking on exactly the Nth request. Counters created only after the first 503 can lose their first increments before the first scrape; short-lived series can be missed. `WAKE_HITS=1` is especially vulnerable to that new-series case. A recently stale replica gauge can also briefly open the keep-awake gate while the Deployment has reached zero. Exact request semantics require a stateful request-aware scaler/proxy.
- The path label usually contains the **Ingress route template**, not the complete raw request URL. If every endpoint is routed under `/`, the standard path regex cannot exclude `/health` separately. Use distinct Ingress paths or metric relabelling. Prometheus regex matchers are fully anchored; adjust the regex for route prefixes/subpaths as needed.
- Missing/empty metrics are errors (`ignoreNullValues: "false"`), not zero traffic. A metric outage can prevent sleep **or wake**; this is not an availability guarantee. Never add `or vector(0)` casually, because it would hide telemetry loss.
- On KEDA versions without `initialCooldownPeriod`, first-creation inactivity follows that version's default semantics and can sleep earlier. Use KEDA 2.14+ when the first idle interval must be protected.

## End-to-end test and recovery

`test --apply` auto-detects a unique ingress-nginx host and literal Exact/Prefix path for the Service. For multiple routes or ImplementationSpecific/regex paths, supply `--test-url https://orders.example.com/safe-path`. The hostname must resolve from your workstation; TLS verification stays enabled. There are no automatic retries, redirects or extra readiness HTTP requests.

The test saves a recovery patch, temporarily sets `cooldownPeriod: 60` and, where supported, `initialCooldownPeriod: 0`, then waits **up to 5 minutes** for desired/actual replicas to be zero and the replica metric to catch up. This includes draining the 2-minute traffic window. It sends exactly the configured number of GETs, reports every initial HTTP code, and waits up to a further 5 minutes for replicas to rise and at least one Deployment Pod to be Ready. It measures both durations from the first hit. Readiness is established from the Deployment controller's observed generation and ready replica count, not from extra HTTP traffic.

EXIT/INT/TERM traps restore cooldown settings after success, failure or Ctrl-C, and stop port-forwarding. Recovery patches test the ScaledObject UID and temporary values before changing anything, so concurrent edits are not silently overwritten. **SIGKILL or machine loss cannot run a Bash trap.** A recovery patch is also saved in the ConfigMap's `test-restore.json`; `status` warns about it, and further enable/test operations stop until recovered. To restore it manually:

```bash
# Replace the names/context with those printed by your command.
kubectl --context YOUR_CONTEXT -n dev get cm orders-api-sleep-mode-state \
  -o json | jq -er '.data["test-restore.json"]' > restore-cooldown.json
kubectl --context YOUR_CONTEXT -n dev patch scaledobject orders-api-sleep-mode \
  --type=json --patch-file=restore-cooldown.json
kubectl --context YOUR_CONTEXT -n dev patch cm orders-api-sleep-mode-state \
  --type=merge -p '{"data":{"test-restore.json":null}}'
```

A failed enable retains recovery state and never discards the original HPA backup. Re-run enable after fixing the error, or run disable with `--apply`. If another HPA now exists with different settings, disable stops and retains the backup for review. Long resource names are shortened deterministically; use the names printed in the logs. Do not delete recovery ConfigMaps or the replica annotation while sleep mode is enabled.

## Trade-offs

- First requests during cold start get **503s**. Mitigate with client retries, a custom error page, or the [KEDA HTTP add-on](https://kedacore.github.io/http-add-on/), which holds requests in a proxy.
- External uptime monitors count as traffic. Exclude their actual metric path labels, or the Service may never sleep. Check the route-template limitation above.
- Cold start ≈ **scrape/ingestion delay + polling interval + image pull + scheduling/readiness**; node provisioning can add more. This is unsuitable for latency-critical production services.
- Scaling Pods to zero saves compute money only if **cluster autoscaler or Karpenter removes the empty nodes**. Other running Pods, resource requests and node constraints affect consolidation.

## Validation and references

```bash
chmod +x sleep-mode.sh tests/mock_cluster.py
bash -n sleep-mode.sh
shellcheck --severity=style sleep-mode.sh
# Offline suite uses CLI doubles, never a cluster; PyYAML is a test-only dependency.
python3 -m pip install PyYAML
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

The included tests cover previews, label discovery, HPA round-trip/recovery, repeated operations, production guards, missing metrics, wake-test behavior and signal cleanup. They do not replace running `test --apply` against your non-production cluster. The sample YAML assumes one original replica and example discovered labels; use the script to render values for your cluster.

Primary references: [KEDA Prometheus scaler](https://keda.sh/docs/2.19/scalers/prometheus/), [ScaledObject settings](https://keda.sh/docs/2.19/reference/scaledobject-spec/), [KEDA activation semantics](https://keda.sh/docs/2.19/concepts/scaling-deployments/), [Prometheus `increase()`](https://prometheus.io/docs/prometheus/latest/querying/functions/#increase), [ingress-nginx monitoring](https://kubernetes.github.io/ingress-nginx/user-guide/monitoring/).
