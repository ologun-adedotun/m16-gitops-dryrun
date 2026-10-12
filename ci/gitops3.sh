#!/usr/bin/env bash
# Third run: does applicationsSync: create-update stop the ApplicationSet deleting Applications?
set -uo pipefail
source ci/lib.sh

H "A. Bootstrap with the model (create-update, preserve, no finalizer in the template)"
installargo
echo "policy override setting: $(kubectl get cm argocd-cmd-params-cm -n argocd -o jsonpath='{.data.applicationsetcontroller\.enable\.policy\.override}') / policy: $(kubectl get cm argocd-cmd-params-cm -n argocd -o jsonpath='{.data.applicationsetcontroller\.policy}')"
kubectl apply -f deploy/bootstrap/root.yaml >/dev/null
waitall 7 900

H "B. Someone adds the finalizer to the template, then the path goes wrong"
python3 - <<'EOF'
p = "deploy/platform/apps.yaml"
s = open(p).read()
s = s.replace("      name: 'mission-{{.path.basename}}'\n", "      name: 'mission-{{.path.basename}}'\n      finalizers:\n        - resources-finalizer.argocd.argoproj.io\n")
open(p, "w").write(s)
EOF
REV=$(push "ApplicationSet: finalizer in the template")
refresh platform; waitapp platform Synced Healthy "$REV" 240
kubectl annotate applicationset mission -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
sleep 20
echo "finalizers on mission-staging: $(kubectl get application mission-staging -n argocd -o jsonpath='{.metadata.finalizers}')"
sed -i 's#path: deploy/envs/\*#path: deploy/env/*#' deploy/platform/apps.yaml
REV=$(push "ApplicationSet: wrong path (create-update)")
refresh platform; waitapp platform Synced Healthy "$REV" 240
kubectl annotate applicationset mission -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
sleep 45
echo "Applications: $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}')"
echo "mission-staging: $(short mission-staging)"
echo "ApplicationSet: $(kubectl get applicationset mission -n argocd -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}; {end}' | cut -c1-300)"
echo "Deployments: $(kubectl get deploy -A -l app.kubernetes.io/instance=mission --no-headers 2>&1 | awk '{print $1"/"$2, $3}' | tr '\n' ' ')"
gw; echo "staging answers: $(hit staging.mission.local)"; echo "production answers: $(hit mission.local)"; kill $PF

H "C. A new environment folder still creates an Application under create-update"
sed -i 's#path: deploy/env/\*#path: deploy/envs/*#' deploy/platform/apps.yaml
mkdir -p deploy/envs/qa
sed 's/staging/qa/g; s/Hello from qa/Hello from qa/' deploy/envs/staging/values.yaml > deploy/envs/qa/values.yaml
REV=$(push "Add a qa environment")
refresh platform; waitapp platform Synced Healthy "$REV" 240
kubectl annotate applicationset mission -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
sleep 30
echo "Applications: $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}')"
echo "mission-qa: $(short mission-qa) $(kubectl get application mission-qa -n argocd -o jsonpath='{.status.conditions[*].message}' | cut -c1-200)"

H "D. Put the model back (and remove qa)"
rm -rf deploy/envs/qa
python3 - <<'EOF'
p = "deploy/platform/apps.yaml"
s = open(p).read()
s = s.replace("      finalizers:\n        - resources-finalizer.argocd.argoproj.io\n", "")
open(p, "w").write(s)
EOF
REV=$(push "ApplicationSet: back to the model")
refresh platform; waitapp platform Synced Healthy "$REV" 240
kubectl annotate applicationset mission -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
sleep 30
echo "Applications after removing the qa folder: $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}')"
echo "mission-qa: $(short mission-qa) $(kubectl get application mission-qa -n argocd -o jsonpath='{.status.conditions[*].message}' | cut -c1-250)"
grep -n 'preserve\|applicationsSync\|finalizers\|path: deploy' deploy/platform/apps.yaml
