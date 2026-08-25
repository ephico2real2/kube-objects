#!/usr/bin/env bash
#
# Run the func-test pipeline LOCALLY, on kind — the same stages ci_build_test.yaml runs on minikube,
# without a 15-minute GitHub Actions round-trip per iteration.
#
# CANONICAL COPY, installed into all four forks as ci_scripts/local-func-test.sh. Edit it in
# splunk-sck-hardening/ and re-install; do not let the four copies drift.
#
# WHY kind AND NOT act. The chart repo's ci/act-local.sh pattern (nektos/act) is the right tool for
# workflows that run commands; this workflow's whole body is cluster orchestration — minikube inside
# act's container is docker-in-docker-in-docker. A kind cluster on the host runs the same k8s stages
# with none of that, and kind's containerd matches what real clusters run anyway.
#
# WHY THIS DOES NOT TOUCH deploy_connector.sh: that script is minikube-specific (`minikube image
# load`) and belongs to the CI flow. This script replays its logic for kind, against the LOCAL chart
# checkout when present so uncommitted chart changes are testable — the CI script clones from GitHub
# and cannot see them.
#
#   ci_scripts/local-func-test.sh              # full pipeline: cluster, splunk, build, deploy, test
#   ci_scripts/local-func-test.sh --keep       # leave the cluster up for postmortem / re-runs
#   ci_scripts/local-func-test.sh --destroy    # tear the cluster down and exit
#
# STAGES (each bounded, each dumps diagnostics on timeout):
#   1. kind cluster `sck-local` with 8000/8088/8089 mapped to localhost (the splunk pod is
#      hostNetwork, so its ports are the node's; the mapping makes them reachable from this Mac)
#   2. splunk via ci_scripts/k8s-splunk.yml — the SAME manifest CI applies
#   3. docker build :recent (docker/build.sh naming, `recent` tag), kind load
#   4. helm install of the fork chart — local checkout preferred, clone fallback
#   5. pod-count wait, then pytest from the chart repo's test/ (same suite CI runs)

set -euo pipefail
cd "$(dirname "$0")/.."
REPO_NAME="$(basename "$(pwd)")"

CLUSTER=sck-local
CHART_LOCAL=/Users/olasumbo/gitRepos/splunk-connect-for-kubernetes
CHART_CLONE_URL=https://github.com/ephico2real2/splunk-connect-for-kubernetes.git
CI_SPLUNK_PASSWORD="${CI_SPLUNK_PASSWORD:-changeme2}"
CI_SPLUNK_HEC_TOKEN="${CI_SPLUNK_HEC_TOKEN:-a6b5e77f-d5f6-415a-bd43-930cecb12959}"
KEEP=false

case "${1:-}" in
  --keep)    KEEP=true ;;
  --destroy) kind delete cluster --name "${CLUSTER}"; exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--keep|--destroy]" >&2; exit 2 ;;
esac

for tool in kind kubectl helm docker python3; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "ERROR: ${tool} not installed" >&2; exit 1; }
done

KCTX="kind-${CLUSTER}"
K="kubectl --context ${KCTX}"

echo "==> stage 1/5: kind cluster ${CLUSTER}"
if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  TMP_CFG="$(mktemp)"
  cat > "${TMP_CFG}" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 8000
    hostPort: 8000
  - containerPort: 8088
    hostPort: 8088
  - containerPort: 8089
    hostPort: 8089
EOF
  kind create cluster --name "${CLUSTER}" --config "${TMP_CFG}"
  rm -f "${TMP_CFG}"
else
  echo "    (cluster exists — reusing; --destroy for a clean slate)"
fi
${K} wait --for=condition=Ready node --all --timeout=180s

echo "==> stage 2/5: splunk (ci_scripts/k8s-splunk.yml — the same manifest CI applies)"
${K} apply -f ci_scripts/k8s-splunk.yml
deadline=$(( $(date +%s) + 600 ))
until ${K} logs splunk 2>/dev/null | grep -q 'Ansible playbook complete'; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "ERROR: splunk did not finish provisioning within 600s" >&2
    ${K} describe pod splunk | tail -30; ${K} logs splunk --tail=60 2>/dev/null
    exit 1
  fi
  printf '.'; sleep 5
done
echo " provisioned"

echo "==> stage 3/5: build ${REPO_NAME}:recent and load into kind"
docker build --platform linux/amd64 --build-arg VERSION=recent \
  -f docker/Dockerfile -t "ephico2real/${REPO_NAME}:recent" .
kind load docker-image "ephico2real/${REPO_NAME}:recent" --name "${CLUSTER}"

echo "==> stage 4/5: deploy the connector chart"
if [ -d "${CHART_LOCAL}/helm-chart/splunk-connect-for-kubernetes" ]; then
  CHART_DIR="${CHART_LOCAL}"
  echo "    using LOCAL chart checkout: ${CHART_DIR} (uncommitted chart changes are visible)"
else
  CHART_DIR="$(mktemp -d)/splunk-connect-for-kubernetes"
  git clone --depth 1 "${CHART_CLONE_URL}" "${CHART_DIR}"
fi
CI_SPLUNK_HOST="$(${K} get pod splunk --template='{{.status.podIP}}')"
helm --kube-context "${KCTX}" uninstall ci-sck >/dev/null 2>&1 || true

# Which subchart image block THIS repo's :recent build overrides. The other three ride on their
# published hardened tags.
case "${REPO_NAME}" in
  fluentd-hec)      SET_PREFIX="splunk-kubernetes-logging.image" ;;
  kube-objects)     SET_PREFIX="splunk-kubernetes-objects.image" ;;
  k8s-metrics)      SET_PREFIX="splunk-kubernetes-metrics.image" ;;
  k8s-metrics-aggr) SET_PREFIX="splunk-kubernetes-metrics.imageAgg" ;;
  *) echo "ERROR: unknown repo ${REPO_NAME}" >&2; exit 1 ;;
esac

# Mirrors deploy_connector.sh: sck_values.yml still names the deleted splunk/* images, so every
# image is pinned with --set, which outranks -f. The under-test override comes LAST — for the same
# key, helm's last --set wins.
helm --kube-context "${KCTX}" install ci-sck \
  --set global.splunk.hec.token="${CI_SPLUNK_HEC_TOKEN}" \
  --set global.splunk.hec.host="${CI_SPLUNK_HOST}" \
  --set kubelet.serviceMonitor.https=true \
  --set splunk-kubernetes-logging.image.name=ephico2real/fluentd-hec \
  --set splunk-kubernetes-logging.image.tag=1.3.3-h1 \
  --set splunk-kubernetes-objects.image.name=ephico2real/kube-objects \
  --set splunk-kubernetes-objects.image.tag=1.2.3-h1 \
  --set splunk-kubernetes-metrics.image.name=ephico2real/k8s-metrics \
  --set splunk-kubernetes-metrics.image.tag=1.2.3-h1 \
  --set splunk-kubernetes-metrics.imageAgg.name=ephico2real/k8s-metrics-aggr \
  --set splunk-kubernetes-metrics.imageAgg.tag=1.2.3-h1 \
  --set "${SET_PREFIX}.name=ephico2real/${REPO_NAME}" \
  --set "${SET_PREFIX}.tag=recent" \
  --set "${SET_PREFIX}.pullPolicy=IfNotPresent" \
  -f "${CHART_DIR}/ci_scripts/sck_values.yml" \
  "${CHART_DIR}/helm-chart/splunk-connect-for-kubernetes"

# 1 node: logging + metrics daemonsets (2) + objects + aggr + splunk = 5
PODS=5
deadline=$(( $(date +%s) + 420 ))
until [ "$(${K} get pod --no-headers 2>/dev/null | grep -c ' Running ')" -ge "${PODS}" ]; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "ERROR: only $(${K} get pod --no-headers | grep -c ' Running ') of ${PODS} pods Running after 420s" >&2
    ${K} get pod -o wide
    for p in $(${K} get pod --no-headers -o custom-columns=:metadata.name | grep -v '^splunk$'); do
      echo "--- ${p} ---"; ${K} logs "${p}" --tail=25 2>/dev/null || true
    done
    exit 1
  fi
  ${K} get pod --no-headers | awk '{print "    "$1, $3}' | sort | head -8; sleep 10
done
echo "    all ${PODS} pods Running"

echo "==> stage 5/5: functional tests (chart repo test/ suite)"
${K} apply -f "${CHART_DIR}/test/test_setup.yaml"
sleep 30
cd "${CHART_DIR}/test"
python3 -m venv .venv-local >/dev/null 2>&1 || true
# shellcheck disable=SC1091
. .venv-local/bin/activate
pip install -q --upgrade pip && pip install -q -r requirements.txt
export PYTHONWARNINGS="ignore:Unverified HTTPS request"
python -m pytest \
  --splunkd-url "https://localhost:8089" \
  --splunk-user admin \
  --splunk-password "${CI_SPLUNK_PASSWORD}" \
  --nodes-count 1 \
  -p no:warnings -s -n auto || TEST_RC=$?

if [ "${KEEP}" = false ]; then
  echo "==> tearing down (use --keep to leave the cluster for postmortem)"
  kind delete cluster --name "${CLUSTER}"
fi
exit "${TEST_RC:-0}"
