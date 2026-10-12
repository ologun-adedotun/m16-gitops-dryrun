#!/usr/bin/env bash
# Second run: does the stricter Application health check make waves wait,
# and what does a wrong ApplicationSet path do when the template has a finalizer?
set -uo pipefail
source ci/lib.sh

H "A. Bootstrap with the stricter health check"
installargo
t0=$(now)
kubectl apply -f deploy/bootstrap/root.yaml >/dev/null
waitall 7 900
echo "bootstrap took $(( $(now) - t0 ))s"
pc_done=$(kubectl get application platform-config -n argocd -o jsonpath='{.status.operationState.finishedAt}')
for a in mission-staging mission-production; do
  echo "$a created $(kubectl get application $a -n argocd -o jsonpath='{.metadata.creationTimestamp}'); platform-config's sync finished $pc_done"
done
echo "platform-config started $(kubectl get application platform-config -n argocd -o jsonpath='{.status.operationState.startedAt}')"

H "B. Wrong path, the template carries the resources finalizer, no preserve"
python3 - <<'EOF'
p = "deploy/platform/apps.yaml"
s = open(p).read()
s = s.replace("preserveResourcesOnDeletion: true", "preserveResourcesOnDeletion: false")
s = s.replace("      name: 'mission-{{.path.basename}}'\n", "      name: 'mission-{{.path.basename}}'\n      finalizers:\n        - resources-finalizer.argocd.argoproj.io\n")
open(p, "w").write(s)
EOF
REV=$(push "ApplicationSet: finalizer in the template, no preserve")
refresh platform; waitapp platform Synced Healthy "$REV" 240
kubectl annotate applicationset mission -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
sleep 20
echo "finalizers on mission-staging: $(kubectl get application mission-staging -n argocd -o jsonpath='{.metadata.finalizers}')"
sed -i 's#path: deploy/envs/\*#path: deploy/env/*#' deploy/platform/apps.yaml
REV=$(push "ApplicationSet: wrong path, with finalizer")
t0=$(now); refresh platform; waitapp platform Synced Healthy "$REV" 240
kubectl annotate applicationset mission -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
sleep 40
echo "after $(( $(now) - t0 ))s"
echo "Applications: $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}')"
echo "Deployments: $(kubectl get deploy -A -l app.kubernetes.io/instance=mission --no-headers 2>&1 | awk '{print $1"/"$2, $3}' | tr '\n' ' ')"
echo "Services in staging: $(kubectl get svc -n staging --no-headers 2>&1 | head -1)"
gw; echo "staging answers: $(hit staging.mission.local)"; echo "production answers: $(hit mission.local)"; kill $PF

H "C. Same mistake, finalizer kept, preserveResourcesOnDeletion: true"
t0=$(now); REV=$(revertpush)
refresh platform; kubectl annotate applicationset mission -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
waitall 7 420; echo "recovered from an outage in $(( $(now) - t0 ))s"
sed -i 's#preserveResourcesOnDeletion: false#preserveResourcesOnDeletion: true#' deploy/platform/apps.yaml
REV=$(push "ApplicationSet: finalizer and preserve")
refresh platform; waitapp platform Synced Healthy "$REV" 240
sed -i 's#path: deploy/envs/\*#path: deploy/env/*#' deploy/platform/apps.yaml
REV=$(push "ApplicationSet: wrong path, finalizer and preserve")
refresh platform; waitapp platform Synced Healthy "$REV" 240
kubectl annotate applicationset mission -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
sleep 40
echo "Applications: $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}')"
echo "Deployments: $(kubectl get deploy -A -l app.kubernetes.io/instance=mission --no-headers 2>&1 | awk '{print $1"/"$2, $3}' | tr '\n' ' ')"
gw; echo "staging answers: $(hit staging.mission.local)"; kill $PF

H "D. Put the model back"
python3 - <<'EOF'
p = "deploy/platform/apps.yaml"
s = open(p).read()
s = s.replace("      finalizers:\n        - resources-finalizer.argocd.argoproj.io\n", "")
s = s.replace("path: deploy/env/*", "path: deploy/envs/*").replace("preserveResourcesOnDeletion: false", "preserveResourcesOnDeletion: true")
open(p, "w").write(s)
EOF
git add -A; git commit -q -m "ApplicationSet: back to the model" || true
git push -q origin HEAD:main
grep -n 'preserve\|finalizers\|path: deploy' deploy/platform/apps.yaml
