#!/usr/bin/env bash
# The argocd CLI and the two app images the experiments use.
set -euo pipefail
curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/download/v3.5.5/argocd-linux-amd64
sudo install -m 0755 /tmp/argocd /usr/local/bin/argocd
argocd version --client --short

IMG=ghcr.io/${GITHUB_REPOSITORY}/maright-app
echo "$GH_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin >/dev/null
docker build -q -t "$IMG:v2.0.0" app
docker tag "$IMG:v2.0.0" "$IMG:v2.1.0"
docker push -q "$IMG:v2.0.0"
docker push -q "$IMG:v2.1.0"
docker logout ghcr.io >/dev/null
docker rmi "$IMG:v2.0.0" "$IMG:v2.1.0" >/dev/null
if docker pull -q "$IMG:v2.1.0" >/dev/null 2>&1; then
  echo "anonymous pull of the app image: allowed (package is public)"
else
  echo "anonymous pull of the app image: refused (package is private); loading the images into kind instead"
  docker build -q -t "$IMG:v2.0.0" app
  docker tag "$IMG:v2.0.0" "$IMG:v2.1.0"
  echo "KINDLOAD=1" >> "$GITHUB_ENV"
fi
