#!/usr/bin/env bash
# Validate the monitoring configuration before it reaches the cluster.
#
#   1. Alert rules:   promtool check + the unit tests in tests/monitoring/
#   2. Alertmanager:  amtool check-config, then routing decisions asserted
#                     (e.g. a critical alert MUST reach Slack, Watchdog must not)
#
# The same script runs locally and in CI (.github/workflows/monitoring-validate.yml).
#
# Needs: promtool + amtool on PATH, python3 with PyYAML.
#   macOS:  brew install prometheus alertmanager && pip3 install pyyaml
#   CI:     installs pinned, checksum-verified releases of both (see the workflow)
#
# Run from anywhere:  bash scripts/check-monitoring.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "ERROR: $*" >&2; exit 1; }
for tool in promtool amtool python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "'$tool' not found on PATH (see the header of this script)"
done
python3 -c 'import yaml' 2>/dev/null || fail "PyYAML missing: pip3 install pyyaml"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1/2  Alert rules =="

# A PrometheusRule is a Kubernetes object; promtool wants the plain rules file,
# which is just its .spec.
python3 - "$WORK" <<'PY'
import glob, os, sys, yaml
work, found = sys.argv[1], 0
for path in sorted(glob.glob('argocd/manifests/monitoring/rules/*.yaml')):
    for doc in yaml.safe_load_all(open(path)):
        if doc and doc.get('kind') == 'PrometheusRule':
            out = os.path.join(work, doc['metadata']['name'] + '.rules.yaml')
            yaml.safe_dump(doc['spec'], open(out, 'w'), sort_keys=False)
            found += 1
if not found:
    sys.exit('no PrometheusRule found under argocd/manifests/monitoring/rules/')
print(f'extracted {found} PrometheusRule file(s)')
PY

for rules in "$WORK"/*.rules.yaml; do
  promtool check rules "$rules"
done

# The tests refer to the extracted file by bare name, so run them beside it.
cp tests/monitoring/*.test.yaml "$WORK"/
for t in "$WORK"/*.test.yaml; do
  (cd "$WORK" && promtool test rules "$(basename "$t")")
done

echo
echo "== 2/2  Alertmanager config and routing =="

# The config is embedded as a string inside the kube-prometheus-stack Application.
# api_url_file points at a mounted Secret that does not exist here, so swap in a
# dummy file; everything else is validated as-is.
echo "dummy" > "$WORK/slack-url"
python3 - "$WORK" <<'PY'
import sys, yaml
work = sys.argv[1]
app = yaml.safe_load(open('argocd/apps/kube-prometheus-stack.yaml'))
values = yaml.safe_load(app['spec']['source']['helm']['values'])
cfg = values['alertmanager']['config']
text = yaml.safe_dump(cfg, sort_keys=False)
real = '/etc/alertmanager/secrets/alertmanager-slack/webhook-url'
assert real in text, 'Slack api_url_file path changed; update this script and the Secret mount together'
open(f'{work}/alertmanager.yaml', 'w').write(text.replace(real, f'{work}/slack-url'))
PY

amtool check-config "$WORK/alertmanager.yaml"

# expected_receiver  label=value ...
# These encode the intent: warnings and criticals reach Slack; info-level alerts,
# Watchdog and anything without a severity do not.
ROUTES=(
  "slack alertname=ShopDown severity=critical namespace=monitoring"
  "slack alertname=ContainerNearMemoryLimit severity=warning namespace=monitoring"
  "slack alertname=KubePodCrashLooping severity=warning namespace=robot-shop"
  "null  alertname=CPUThrottlingHigh severity=info namespace=robot-shop"
  "null  alertname=Watchdog severity=none"
  "null  alertname=InfoInhibitor severity=none namespace=monitoring"
  "null  alertname=NoSeverityLabel namespace=monitoring"
)
bad=0
for spec in "${ROUTES[@]}"; do
  expected="${spec%% *}"
  labels="${spec#* }"
  # shellcheck disable=SC2086
  got="$(amtool config routes test --config.file="$WORK/alertmanager.yaml" $labels | tail -1)"
  if [ "$got" = "$expected" ]; then
    printf '  ok    %-5s <- %s\n' "$got" "$labels"
  else
    printf '  FAIL  expected %s, got %s <- %s\n' "$expected" "$got" "$labels"
    bad=1
  fi
done
[ "$bad" -eq 0 ] || fail "alert routing does not match the intended receivers"

echo
echo "All monitoring checks passed."
