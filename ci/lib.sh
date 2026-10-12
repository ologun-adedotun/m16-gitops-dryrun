# Helpers shared by the experiment scripts.
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
