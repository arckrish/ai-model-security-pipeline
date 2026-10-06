#!/usr/bin/env bash
# Debug: why ai-sec-05-storage sync is Unknown
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/.cursor/debug-968b1a.log"
NS_GITOPS="${NS_GITOPS:-openshift-gitops}"

log() {
  # #region agent log
  local hid="$1" loc="$2" msg="$3" data="$4"
  python3 - "$LOG" "$hid" "$loc" "$msg" "$data" <<'PY'
import json,sys,time
path,hid,loc,msg,data=sys.argv[1:6]
try:
  payload_data=json.loads(data)
except Exception:
  payload_data={"raw": data}
rec={"sessionId":"968b1a","runId":"pre-fix","hypothesisId":hid,"location":loc,"message":msg,"data":payload_data,"timestamp":int(time.time()*1000)}
with open(path,"a") as f:
  f.write(json.dumps(rec)+"\n")
print(json.dumps(rec))
PY
  # #endregion
}

# H-A: kustomization lists secret.yaml but file missing locally / in git
exists_local=0
[[ -f "$ROOT/instances/minio/secret.yaml" ]] && exists_local=1
in_git=0
git -C "$ROOT" cat-file -e HEAD:instances/minio/secret.yaml 2>/dev/null && in_git=1 || true
listed=0
grep -q 'secret.yaml' "$ROOT/instances/minio/kustomization.yaml" && listed=1
log A "instances/minio/kustomization.yaml" "secret.yaml presence" \
  "{\"listedInKustomization\":$listed,\"existsLocal\":$exists_local,\"existsInGitHEAD\":$in_git}"

# H-B: gitignore blocking secret.yaml
ignored="$(git -C "$ROOT" check-ignore -v instances/minio/secret.yaml 2>&1 || true)"
log B ".gitignore" "check-ignore for instances/minio/secret.yaml" \
  "{\"checkIgnore\":\"$(echo "$ignored" | sed 's/\"/\\"/g')\"}"

# H-C: local kustomize build fails the same way Argo does
build_rc=0
build_err="$( (kubectl kustomize "$ROOT/overlays/05-storage" 2>&1 || oc kustomize "$ROOT/overlays/05-storage" 2>&1) | tail -c 800 )" || build_rc=$?
# if both fail, capture via kustomize if present
if ! command -v kubectl >/dev/null 2>&1 && ! command -v oc >/dev/null 2>&1; then
  build_err="no kubectl/oc"
  build_rc=127
else
  set +e
  build_err="$(oc kustomize "$ROOT/overlays/05-storage" 2>&1 | tail -c 800)"
  build_rc=${PIPESTATUS[0]}
  set -e
fi
log C "overlays/05-storage" "local oc kustomize result" \
  "{\"exitCode\":$build_rc,\"stderrTail\":\"$(echo "$build_err" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])')\"}"

# H-D: Argo app ComparisonError still present
set +e
app_json="$(oc get application ai-sec-05-storage -n "$NS_GITOPS" -o json 2>&1)"
app_rc=$?
set -e
if [[ $app_rc -eq 0 ]]; then
  python3 - "$LOG" "$app_json" <<'PY'
import json,sys,time
path=sys.argv[1]
app=json.loads(sys.argv[2])
st=app.get("status") or {}
conds=st.get("conditions") or []
msg=" | ".join(f"{c.get('type')}={c.get('status')}: {(c.get('message') or '')[:300]}" for c in conds)
rec={
  "sessionId":"968b1a","runId":"pre-fix","hypothesisId":"D",
  "location":"openshift-gitops/ai-sec-05-storage",
  "message":"argo application status",
  "data":{
    "sync": (st.get("sync") or {}).get("status"),
    "health": (st.get("health") or {}).get("status"),
    "revision": (st.get("sync") or {}).get("revision"),
    "conditions": msg,
    "mentionsSecretYaml": "secret.yaml" in msg,
  },
  "timestamp": int(time.time()*1000),
}
with open(path,"a") as f: f.write(json.dumps(rec)+"\n")
print(json.dumps(rec))
PY
else
  log D "openshift-gitops/ai-sec-05-storage" "oc get application failed" \
    "{\"exitCode\":$app_rc,\"err\":\"$(echo "$app_json" | head -c 200 | sed 's/\"/\\"/g')\"}"
fi

# H-E: Application path/revision mismatch
set +e
path_rev="$(oc get application ai-sec-05-storage -n "$NS_GITOPS" -o jsonpath='path={.spec.source.path} rev={.spec.source.targetRevision} repo={.spec.source.repoURL}{"\n"}' 2>&1)"
set -e
log E "ai-sec-05-storage.spec.source" "path revision repo" \
  "{\"raw\":\"$(echo "$path_rev" | sed 's/\"/\\"/g')\"}"

echo "Wrote diagnostics to $LOG"
