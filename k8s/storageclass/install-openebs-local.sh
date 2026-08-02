#!/usr/bin/env sh
# Installs the OpenEBS Local PV HostPath provisioner without Helm.
#
# Configuration examples:
#   ./install-openebs-local.sh
#   LOCALPV_BASE_PATH=/mnt/openebs/local ./install-openebs-local.sh
#   STORAGE_CLASS_NAME=openebs-local-prod IS_DEFAULT_STORAGE_CLASS=false ./install-openebs-local.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OPENEBS_MANIFEST_URL=${OPENEBS_MANIFEST_URL:-https://openebs.github.io/charts/openebs-operator-lite.yaml}
STORAGE_CLASS_NAME=${STORAGE_CLASS_NAME:-openebs-local}
LOCALPV_BASE_PATH=${LOCALPV_BASE_PATH:-/var/openebs/local}
IS_DEFAULT_STORAGE_CLASS=${IS_DEFAULT_STORAGE_CLASS:-false}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-180s}

fail() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

case "$(uname -s)" in
  Darwin)
    OS_NAME=macOS
    ;;
  Linux)
    OS_NAME=Linux
    ;;
  *)
    fail "Unsupported operating system: $(uname -s). Supported operating systems are macOS and Linux."
    ;;
esac

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required. Install kubectl and configure a cluster context first."
kubectl version --request-timeout=10s >/dev/null 2>&1 || fail "Cannot reach the Kubernetes API using the current kubectl context."

case "$STORAGE_CLASS_NAME" in
  '' | *[!a-z0-9.-]* | .* | *.)
    fail "STORAGE_CLASS_NAME must be a lowercase DNS-compatible name."
    ;;
esac

case "$LOCALPV_BASE_PATH" in
  /*)
    ;;
  *)
    fail "LOCALPV_BASE_PATH must be an absolute path on every Kubernetes node."
    ;;
esac

case "$LOCALPV_BASE_PATH" in
  *[!A-Za-z0-9._/-]*)
    fail "LOCALPV_BASE_PATH may contain only letters, numbers, '.', '_', '-', and '/'."
    ;;
esac

case "$IS_DEFAULT_STORAGE_CLASS" in
  true | false)
    ;;
  *)
    fail "IS_DEFAULT_STORAGE_CLASS must be true or false."
    ;;
esac

case "$WAIT_TIMEOUT" in
  *[!0-9smh]*)
    fail "WAIT_TIMEOUT must be a Kubernetes duration, for example 180s or 5m."
    ;;
esac

TEMP_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/openebs-local-storageclass.XXXXXX")
trap 'rm -f "$TEMP_MANIFEST"' EXIT HUP INT TERM

sed \
  -e "s|__STORAGE_CLASS_NAME__|$STORAGE_CLASS_NAME|g" \
  -e "s|__LOCALPV_BASE_PATH__|$LOCALPV_BASE_PATH|g" \
  -e "s|__IS_DEFAULT_STORAGE_CLASS__|$IS_DEFAULT_STORAGE_CLASS|g" \
  "$SCRIPT_DIR/openebs-local.yaml" > "$TEMP_MANIFEST"

printf 'Installing OpenEBS Local PV HostPath on %s...\n' "$OS_NAME"
kubectl apply -f "$OPENEBS_MANIFEST_URL"

# The legacy lightweight manifest also installs NDM for Local PV Device support.
# HostPath does not use NDM, and desktop Kubernetes nodes can legitimately omit
# /run/udev, which otherwise leaves the NDM DaemonSet pending indefinitely.
printf '%s\n' 'Removing the unused NDM DaemonSet (HostPath-only installation)...'
kubectl delete daemonset/openebs-ndm --namespace openebs --ignore-not-found

printf 'Waiting for the OpenEBS Local PV provisioner...\n'
kubectl rollout status deployment/openebs-localpv-provisioner \
  --namespace openebs \
  --timeout="$WAIT_TIMEOUT"

kubectl apply -f "$TEMP_MANIFEST"
kubectl get storageclass "$STORAGE_CLASS_NAME"

printf '%s\n' "OpenEBS Local PV HostPath is ready. Use storageClassName: $STORAGE_CLASS_NAME in PVC manifests."
printf '%s\n' "Volumes will be created under $LOCALPV_BASE_PATH on the node selected for the Pod."
