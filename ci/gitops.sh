#!/usr/bin/env bash
# Module 16 authoring test: Argo CD in kind, reading this repository.
set -uo pipefail
IMG=ghcr.io/${GITHUB_REPOSITORY}/maright-app
CLUSTER=chart-testing
H() { echo; echo "=== $* ==="; }
now() { date +%s; }
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

loadimages() { if [ "${KINDLOAD:-0}" = 1 ]; then kind load docker-image "$IMG:v2.0.0" "$IMG:v2.1.0" --name "$1"; fi; }
installargo() {
  helm install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.10.3 \
    -n argocd --create-namespace -f deploy/argocd/values.yaml --wait --timeout 6m >/dev/null
}
refresh() { for a in "$@"; do kubectl annotate application "$a" -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1; done; }
state() { kubectl get application "$1" -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}@{.status.sync.revision}' 2>/dev/null; }
short() { local s; s=$(state "$1"); echo "${s%@*}@${s##*@}" | cut -c1-40; }
# waitapp NAME SYNC HEALTH [REVISION] [TIMEOUT]
waitapp() {
  local n=$1 s=$2 h=$3 rev=${4:-} to=${5:-300} t0 st
  t0=$(now)
  while :; do
    st=$(state "$n")
    if [[ "$st" == "$s/$h@"* ]] && { [ -z "$rev" ] || [[ "$st" == *"@$rev" ]]; }; then
      echo "$n reached $s/$h after $(( $(now) - t0 ))s"; return 0; fi
    if (( $(now) - t0 > to )); then echo "$n TIMED OUT after ${to}s at ${st:-nothing}"; return 1; fi
    refresh "$n"; sleep 4
  done
}
# waitall COUNT TIMEOUT: every Application Synced/Healthy, printing changes as they happen
waitall() {
  local want=$1 to=$2 t0 prev="" cur ok
  t0=$(now)
  while :; do
    cur=$(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status} {end}' 2>/dev/null)
    if [ "$cur" != "$prev" ]; then echo "+$(( $(now) - t0 ))s  $cur"; prev=$cur; fi
    ok=$(echo "$cur" | tr ' ' '\n' | grep -c '=Synced/Healthy$')
    if [ "$ok" -ge "$want" ]; then echo "all $ok Synced/Healthy after $(( $(now) - t0 ))s"; return 0; fi
    if (( $(now) - t0 > to )); then echo "NOT all healthy after ${to}s"; return 1; fi
    sleep 5
  done
}
push() { git add -A; git commit -q -m "$1"; git push -q origin HEAD:main; git rev-parse HEAD; }
revertpush() { git revert --no-edit HEAD >/dev/null; git push -q origin HEAD:main; git rev-parse HEAD; }
gw() {
  local svc
  svc=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=mission -o jsonpath='{.items[0].metadata.name}')
  kubectl port-forward -n envoy-gateway-system "svc/$svc" 8081:80 8443:443 >/dev/null 2>&1 &
  PF=$!; sleep 4
}
hit() { curl -s -m 5 -o /tmp/body -w "%{http_code}" -H "Host: $1" http://127.0.0.1:8081/; echo " $(cat /tmp/body 2>/dev/null)"; }

loadimages "$CLUSTER"

H "0. Install Argo CD (chart 10.10.3)"
t0=$(now); installargo; echo "installed in $(( $(now) - t0 ))s"
kubectl get deploy,statefulset -n argocd --no-headers | awk '{print $1}'
helm list -n argocd -o json | python3 -c 'import json,sys; r=json.load(sys.stdin)[0]; print(r["chart"], "app", r["app_version"])'

H "1. A wave mistake: the Gateway config before its controllers"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: early-config
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/${GITHUB_REPOSITORY}.git
    targetRevision: main
    path: deploy/platform-config
  destination:
    server: https://kubernetes.default.svc
    namespace: infra
  syncPolicy:
    automated: {}
EOF
sleep 45
echo "state: $(short early-config)"
kubectl get application early-config -n argocd -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}{"\n"}' | cut -c1-400
kubectl get application early-config -n argocd -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' | cut -c1-300
kubectl get ns infra staging production --no-headers 2>&1 | cut -c1-80
kubectl delete application early-config -n argocd --wait=true >/dev/null

H "2. Bootstrap: one Application applied by hand, everything else from Git"
t0=$(now)
kubectl apply -f deploy/bootstrap/root.yaml >/dev/null
waitall 7 900
echo "bootstrap took $(( $(now) - t0 ))s"
kubectl get applications -n argocd
kubectl get applicationset mission -n argocd -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
for a in cert-manager envoy-gateway platform-config mission-staging; do
  echo "$a sync waves seen: $(kubectl get application $a -n argocd -o jsonpath='{.status.operationState.syncResult.resources[*].syncPhase}' | tr ' ' '\n' | sort | uniq -c | tr '\n' ' ')"
done
echo "platform's own operation started $(kubectl get application platform -n argocd -o jsonpath='{.status.operationState.startedAt}') finished $(kubectl get application platform -n argocd -o jsonpath='{.status.operationState.finishedAt}')"
for a in cert-manager envoy-gateway metrics-server platform-config mission-staging mission-production; do
  echo "$a reconciledAt/finishedAt: $(kubectl get application $a -n argocd -o jsonpath='{.status.operationState.startedAt} -> {.status.operationState.finishedAt}')"
done
echo "helm test hook pod in Argo's resources? $(kubectl get application mission-staging -n argocd -o jsonpath='{.status.resources[*].kind}' | tr ' ' '\n' | sort | uniq -c | tr '\n' ' ')"
helm list -A 2>/dev/null | head -5
echo "Gateway: $(kubectl get gateway mission -n infra -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}')"

H "3. Traffic through the Gateway"
gw
echo "staging:    $(hit staging.mission.local)"
echo "production: $(hit mission.local)"
kubectl get secret mission-ca -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/ca1.crt
curl -s -m 5 --cacert /tmp/ca1.crt --resolve mission.local:8443:127.0.0.1 https://mission.local:8443/health -w " TLS exit=%{exitcode}\n"
kill $PF

H "4. CI's job, done by hand: move staging to v2.1.0"
sed -i 's/^  tag: .*/  tag: v2.1.0/' deploy/envs/staging/values.yaml
REV=$(push "Move staging to v2.1.0")
t0=$(now); refresh mission-staging
waitapp mission-staging Synced Healthy "$REV" 300
kubectl get deploy mission -n staging -o jsonpath='image now: {.spec.template.spec.containers[0].image}{"\n"}'

H "5. Drift: three changes made with kubectl"
t0=$(now)
kubectl scale deployment mission -n staging --replicas=5 >/dev/null
kubectl patch configmap mission -n staging --type merge -p '{"data":{"GREETING":"changed by hand"}}' >/dev/null
kubectl annotate deployment mission -n staging changed-by=hand --overwrite >/dev/null
for i in $(seq 40); do
  r=$(kubectl get deploy mission -n staging -o jsonpath='{.spec.replicas}')
  g=$(kubectl get cm mission -n staging -o jsonpath='{.data.GREETING}')
  if [ "$r" = 2 ] && [ "$g" = "Hello from staging" ]; then echo "replicas and ConfigMap put back after $(( $(now) - t0 ))s"; break; fi
  sleep 2
done
echo "replicas=$(kubectl get deploy mission -n staging -o jsonpath='{.spec.replicas}') greeting=$(kubectl get cm mission -n staging -o jsonpath='{.data.GREETING}')"
echo "annotation not in Git, after the same wait: changed-by=$(kubectl get deploy mission -n staging -o jsonpath='{.metadata.annotations.changed-by}')"
echo "app state: $(short mission-staging)"
kubectl annotate deployment mission -n staging changed-by- >/dev/null

H "6. A broken commit that fails the chart's schema"
sed -i 's/^config:/replicaCount: "two"\nconfig:/' deploy/envs/staging/values.yaml
REV=$(push "Break staging: replicas as text")
refresh mission-staging; sleep 30; refresh mission-staging; sleep 10
echo "state: $(short mission-staging)"
kubectl get application mission-staging -n argocd -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' | cut -c1-400
echo "pods still running: $(kubectl get pods -n staging -l app.kubernetes.io/instance=mission --field-selector=status.phase=Running --no-headers | wc -l)"
REV=$(revertpush)
waitapp mission-staging Synced Healthy "$REV" 300

H "7. A broken commit that passes every check: an image that does not exist"
sed -i 's/^  tag: .*/  tag: v9.9.9/' deploy/envs/staging/values.yaml
REV=$(push "Move staging to v9.9.9")
t0=$(now)
waitapp mission-staging Synced Progressing "$REV" 180
sleep 60
echo "after $(( $(now) - t0 ))s: $(short mission-staging) message: $(kubectl get application mission-staging -n argocd -o jsonpath='{.status.health.message}')"
kubectl get pods -n staging -l app.kubernetes.io/instance=mission --no-headers | awk '{print $1, $2, $3}'
gw; echo "staging still answers: $(hit staging.mission.local)"; kill $PF
H "7b. The Argo CD rollback button, with automated sync on"
kubectl config set-context --current --namespace=argocd >/dev/null
argocd app history mission-staging --core 2>&1 | tail -n 6
argocd app rollback mission-staging --core 2>&1 | tail -n 2
kubectl config set-context --current --namespace=default >/dev/null
H "7c. Roll back with git revert"
t0=$(now)
REV=$(revertpush)
waitapp mission-staging Synced Healthy "$REV" 300
echo "revert to healthy: $(( $(now) - t0 ))s"

H "8. Promotion: production gets staging's tag"
sed -i 's/^  tag: .*/  tag: v2.1.0/' deploy/envs/production/values.yaml
REV=$(push "Promote v2.1.0 to production")
t0=$(now); refresh mission-production
waitapp mission-production Synced Healthy "$REV" 300
kubectl get deploy mission -n production -o jsonpath='production image: {.spec.template.spec.containers[0].image}{"\n"}'

H "9. Prune: remove something from Git"
printf '\npodDisruptionBudget:\n  enabled: false\n' >> deploy/envs/staging/values.yaml
echo "before: $(kubectl get pdb -n staging --no-headers 2>&1 | awk '{print $1}')"
REV=$(push "Staging without a PodDisruptionBudget")
t0=$(now); refresh mission-staging
waitapp mission-staging Synced Healthy "$REV" 300
echo "after $(( $(now) - t0 ))s: $(kubectl get pdb -n staging --no-headers 2>&1 | head -1)"
REV=$(revertpush); refresh mission-staging
waitapp mission-staging Synced Healthy "$REV" 300

appsetcheck() {
  local rev=$1
  refresh platform
  waitapp platform Synced Healthy "$rev" 240 || waitapp platform Synced Progressing "$rev" 60
  kubectl annotate applicationset mission -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
  sleep 40
  echo "Applications: $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}')"
  echo "ApplicationSet: $(kubectl get applicationset mission -n argocd -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}; {end}' | cut -c1-300)"
  echo "Deployments: $(kubectl get deploy -A -l app.kubernetes.io/instance=mission --no-headers 2>&1 | awk '{print $1"/"$2, $3}' | tr '\n' ' ')"
  gw; echo "staging answers: $(hit staging.mission.local)"; kill $PF
}
H "10. A wrong path in the ApplicationSet (preserveResourcesOnDeletion: true)"
sed -i 's#path: deploy/envs/\*#path: deploy/env/*#' deploy/platform/apps.yaml
appsetcheck "$(push 'ApplicationSet: wrong path')"
t0=$(now); REV=$(revertpush)
refresh platform; kubectl annotate applicationset mission -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
waitall 7 300; echo "path restored, apps back in $(( $(now) - t0 ))s"
H "10b. The same mistake without preserveResourcesOnDeletion"
sed -i 's#path: deploy/envs/\*#path: deploy/env/*#; s#preserveResourcesOnDeletion: true#preserveResourcesOnDeletion: false#' deploy/platform/apps.yaml
appsetcheck "$(push 'ApplicationSet: wrong path, no preserve')"
t0=$(now); REV=$(revertpush)
refresh platform; kubectl annotate applicationset mission -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite >/dev/null
waitall 7 420; echo "recovered in $(( $(now) - t0 ))s"
gw; echo "staging: $(hit staging.mission.local)"; echo "production: $(hit mission.local)"; kill $PF

H "11. An Application stuck deleting"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: scratch
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/${GITHUB_REPOSITORY}.git
    targetRevision: main
    path: ci/scratch
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated: {}
EOF
waitapp scratch Synced Healthy "" 120
kubectl scale statefulset argocd-application-controller -n argocd --replicas=0 >/dev/null
sleep 10
kubectl delete application scratch -n argocd --wait=false >/dev/null
sleep 30
echo "after 30s with no controller: deletionTimestamp=$(kubectl get application scratch -n argocd -o jsonpath='{.metadata.deletionTimestamp}') finalizers=$(kubectl get application scratch -n argocd -o jsonpath='{.metadata.finalizers}')"
kubectl scale statefulset argocd-application-controller -n argocd --replicas=1 >/dev/null
t0=$(now)
kubectl wait --for=delete application/scratch -n argocd --timeout=180s >/dev/null 2>&1 && echo "deleted $(( $(now) - t0 ))s after the controller came back"
echo "scratch ConfigMap: $(kubectl get cm scratch -n default --no-headers 2>&1 | cut -c1-60)"
waitall 7 300 >/dev/null; echo "all apps healthy again"

H "12. Argo CD's own accounts"
kubectl port-forward svc/argocd-server -n argocd 8444:443 >/dev/null 2>&1 &
PFA=$!; sleep 5
INIT=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d)
echo "::add-mask::$INIT"
NEWPW=$(openssl rand -base64 24); echo "::add-mask::$NEWPW"
TPW=$(openssl rand -base64 24); echo "::add-mask::$TPW"
argocd login localhost:8444 --username admin --password "$INIT" --insecure >/dev/null 2>&1 && echo "admin login with the initial password: ok"
argocd account update-password --account admin --current-password "$INIT" --new-password "$NEWPW" >/dev/null 2>&1 && echo "admin password changed"
argocd login localhost:8444 --username admin --password "$INIT" --insecure >/dev/null 2>&1 && echo "old password still works (wrong)" || echo "old password refused"
argocd login localhost:8444 --username admin --password "$NEWPW" --insecure >/dev/null 2>&1 && echo "admin login with the new password: ok"
argocd account update-password --account trainer --current-password "$NEWPW" --new-password "$TPW" >/dev/null 2>&1 && echo "trainer password set"
kubectl delete secret argocd-initial-admin-secret -n argocd >/dev/null && echo "initial admin Secret deleted"
argocd account list 2>&1 | head -5
argocd login localhost:8444 --username trainer --password "$TPW" --insecure >/dev/null 2>&1 && echo "trainer login: ok"
echo "trainer sees: $(argocd app list -o name 2>&1 | tr '\n' ' ')"
echo "trainer can-i sync: $(argocd account can-i sync applications '*' 2>&1)"
echo "trainer tries a sync: $(argocd app sync mission-staging 2>&1 | tail -n 1 | cut -c1-200)"
echo "trainer tries to delete: $(argocd app delete mission-staging --yes 2>&1 | tail -n 1 | cut -c1-200)"
argocd logout localhost:8444 >/dev/null 2>&1
kill $PFA
unset INIT NEWPW TPW

H "13. Rebuild the whole cluster from Git"
FP1=$(openssl x509 -in /tmp/ca1.crt -noout -fingerprint -sha256)
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
echo "old cluster deleted"
t0=$(now)
kind create cluster --name rebuild --wait 120s >/dev/null 2>&1 && echo "new cluster in $(( $(now) - t0 ))s"
loadimages rebuild
installargo; echo "Argo CD installed at +$(( $(now) - t0 ))s"
kubectl apply -f deploy/bootstrap/root.yaml >/dev/null
waitall 7 900
echo "REBUILD TOTAL: $(( $(now) - t0 ))s from an empty machine to both environments healthy"
gw
echo "staging:    $(hit staging.mission.local)"
echo "production: $(hit mission.local)"
kubectl get secret mission-ca -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/ca2.crt
FP2=$(openssl x509 -in /tmp/ca2.crt -noout -fingerprint -sha256)
[ "$FP1" = "$FP2" ] && echo "CA after rebuild: SAME" || echo "CA after rebuild: DIFFERENT (a new root)"
curl -s -m 5 -o /dev/null --cacert /tmp/ca1.crt --resolve mission.local:8443:127.0.0.1 https://mission.local:8443/health -w "old CA trusted by a client: exit %{exitcode}\n"
curl -s -m 5 -o /dev/null --cacert /tmp/ca2.crt --resolve mission.local:8443:127.0.0.1 https://mission.local:8443/health -w "new CA: exit %{exitcode}\n"
kill $PF
echo "initial admin Secret back after rebuild: $(kubectl get secret argocd-initial-admin-secret -n argocd --no-headers 2>/dev/null | wc -l)"
echo "production image after rebuild: $(kubectl get deploy mission -n production -o jsonpath='{.spec.template.spec.containers[0].image}')"
