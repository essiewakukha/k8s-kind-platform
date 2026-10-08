#!/usr/bin/env bash
# Offline checks: unit tests, shell syntax, and rendering plus schema-validating
# both overlays. Needs kubectl; kubeconform is used when installed.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

echo ">> Shell syntax"
bash -n scripts/*.sh
echo "   ok"

echo ">> Unit tests"
python3 -m unittest discover -s tests -v

for OVERLAY in dev prod; do
  echo ">> Render overlay: $OVERLAY"
  kubectl kustomize "k8s/overlays/$OVERLAY" > "/tmp/shop-$OVERLAY.yaml"
  echo "   $(grep -c '^kind:' "/tmp/shop-$OVERLAY.yaml") objects rendered"

  if command -v kubeconform > /dev/null; then
    echo ">> Schema validation (kubeconform): $OVERLAY"
    kubeconform -strict -summary "/tmp/shop-$OVERLAY.yaml"
  else
    echo "   (kubeconform not installed, skipping schema validation)"
  fi
done

echo ""
echo "All checks passed."