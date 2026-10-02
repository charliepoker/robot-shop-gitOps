#!/usr/bin/env bash
# Validate the monitoring configuration before it reaches the cluster.
#
#   1. Manifest sanity: every YAML under argocd/apps and argocd/manifests is a real
#                       Kubernetes object (has apiVersion and kind)
#   2. Alert rules:     promtool check + the unit tests in tests/monitoring/
#   3. Alertmanager:    amtool check-config, then routing decisions asserted
#                       (e.g. a critical alert MUST reach Slack, Watchdog must not)
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

echo "== 1/3  Manifest sanity =="

# ArgoCD applies EVERY .yaml file under an Application's path as a Kubernetes object.
# One stray file (a unit test, a values file, notes) that is not one makes the whole
# Application fail to render, and everything else in that folder stops syncing with
# it. This has happened here three times, always as a file one folder off.
python3 - <<'PY'
import glob, sys, yaml

problems, checked = [], 0
for pattern in ('argocd/apps/**/*.yaml', 'argocd/apps/**/*.yml',
                'argocd/manifests/**/*.yaml', 'argocd/manifests/**/*.yml'):
    for path in sorted(glob.glob(pattern, recursive=True)):
        try:
            docs = list(yaml.safe_load_all(open(path)))
        except yaml.YAMLError as err:
            problems.append(f'{path}: not valid YAML ({type(err).__name__})')
            continue
        checked += 1
        for number, doc in enumerate(docs, start=1):
            if doc is None:
                continue
            if not isinstance(doc, dict) or 'apiVersion' not in doc or 'kind' not in doc:
                what = ('top-level keys: ' + ', '.join(list(doc)[:3])) if isinstance(doc, dict) else 'it is plain text, not a mapping'
                problems.append(f'{path} (document {number}): no apiVersion/kind; {what}')

if problems:
    print('These files are not Kubernetes objects, but ArgoCD would try to apply them:', file=sys.stderr)
    for p in problems:
        print(f'  - {p}', file=sys.stderr)
    print('\nMove them outside argocd/ (unit tests belong in tests/monitoring/).', file=sys.stderr)
    sys.exit(1)
print(f'{checked} manifest files checked; all are Kubernetes objects')
PY

echo
echo "== 2/3  Alert rules =="

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

# Rules without tests are not allowed through: a rule that always fires or never
# fires looks fine to a syntax check.
shopt -s nullglob
tests=(tests/monitoring/*.test.yaml)
if [ "${#tests[@]}" -eq 0 ]; then
  stray="$(find . -name '*.test.yaml' -not -path './.git/*' 2>/dev/null || true)"
  if [ -n "$stray" ]; then
    echo "Found test file(s) in the wrong place:" >&2
    echo "$stray" | sed 's/^/  /' >&2
  fi
  fail "no unit tests found at tests/monitoring/*.test.yaml"
fi

# The tests refer to the extracted file by bare name, so run them beside it.
cp "${tests[@]}" "$WORK"/
for t in "${tests[@]}"; do
  (cd "$WORK" && promtool test rules "$(basename "$t")")
done

echo
echo "== 3/3  Alertmanager config and routing =="

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