# AI Model Security Pipeline — GitOps deployment runbook
# Design: README.md, instances/gitops/README.md, script.sh (manual overlay path)
# App-of-Apps: instances/gitops/application-root.yaml → instances/gitops/apps/
#
# Prerequisites:
#   oc login ...
#   OpenShift GitOps operator Ready (Application CRD present)
#   GPU nodes: infra/prereqs/ocp-gpu-setup/README.md (MachineSet still manual)
#   Edit repoURL / targetRevision in instances/gitops/application-root.yaml
#     and instances/gitops/apps/*.yaml if using a fork
#   Set APPS_DOMAIN from this cluster:
#     APPS_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
#     echo "inference-gateway.${APPS_DOMAIN}"
#   Edit instances/gateway/gateway.yaml hostname (REPLACE_WITH_CLUSTER_APPS_DOMAIN)
#   Credentials: cp .env.example .env and set HF_TOKEN, QUAY_*, MINIO_ROOT_*
#   (gitops-scripts.sh creates cluster Secrets from .env — no quay/minio yaml files)
#
# Run phase-by-phase: copy/paste each phase block into your shell
# (do not run bash gitops-scripts.sh end-to-end).

cd "$(dirname "$0")"

source ./.env

export QUAY_SERVER="${QUAY_SERVER:-quay.io}"
export QUAY_EMAIL="${QUAY_EMAIL:-}"
export QUAY_SECRET_NAME="${QUAY_SECRET_NAME:-sudash-modelpipeline-pull-secret}"

# Platform namespaces — override via environment before running commands below.
export NS_MODEL_INGRESS="${NS_MODEL_INGRESS:-model-ingress}"
export NS_MODEL_EVAL="${NS_MODEL_EVAL:-model-eval}"
export NS_MODEL_TEST="${NS_MODEL_TEST:-model-test}"
export NS_MODEL_SANDBOX="${NS_MODEL_SANDBOX:-model-sandbox}"
export NS_BUILD_IMAGE="${NS_BUILD_IMAGE:-build-image}"
export NS_MINIO="${NS_MINIO:-minio-system}"
export NS_GITOPS="${NS_GITOPS:-openshift-gitops}"

# =============================================================================
# Phase 0: Apply App-of-Apps (single apply)
# Overlay: 17-gitops → instances/gitops (root Application only)
# Children sync overlays 00–15 + model-ingress + model-test promotion (waves 0–16).
# =============================================================================
oc apply -k ./instances/gitops/

# Verify root + children:
oc get application ai-model-security-platform -n "${NS_GITOPS}"
oc get applications -n "${NS_GITOPS}" -l app.kubernetes.io/part-of=ai-model-security-pipeline

# RHCL (connectivity-link) Subscription uses installPlanApproval: Manual.
# Wait until ai-sec-02-operators has created the InstallPlan, then approve:
#   oc get application ai-sec-02-operators -n "${NS_GITOPS}"
oc get installplan -n kuadrant-system
# Approve every InstallPlan that is not yet approved (safe if already approved):
for ip in $(oc get installplan -n kuadrant-system -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}'); do
  oc patch installplan "${ip}" -n kuadrant-system --type merge -p '{"spec":{"approved":true}}'
done
oc get csv -n kuadrant-system
# oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n kuadrant-system --timeout=600s

# =============================================================================
# Phase 1: MinIO root from .env, then wait for storage (overlay 05 via Argo)
# =============================================================================
oc create secret generic minio-root -n "${NS_MINIO}" \
  --from-literal=MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  --from-literal=MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
  --dry-run=client -o yaml | oc apply -f -
oc rollout restart deployment/minio -n "${NS_MINIO}" || true
oc rollout status deployment/minio -n "${NS_MINIO}" --timeout=300s
oc wait --for=condition=Available deployment/minio -n "${NS_MINIO}" --timeout=600s
oc wait --for=condition=complete job/minio-bucket-init -n "${NS_MINIO}" --timeout=300s
oc get route minio-api minio-console -n "${NS_MINIO}"

# =============================================================================
# Phase 2: Zone secrets from .env (no quay-secret.yaml / minio-s3-secret.yaml)
# =============================================================================
for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}" "${NS_MODEL_TEST}"; do
  oc create secret generic minio-s3 -n "${ns}" \
    --from-literal=MINIO_ENDPOINT=http://minio.minio-system.svc:9000 \
    --from-literal=AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
    --from-literal=AWS_REGION=us-east-1 \
    --from-literal=AWS_ENDPOINT_URL=http://minio.minio-system.svc:9000 \
    --from-literal=AWS_DEFAULT_REGION=us-east-1 \
    --from-literal=S3_USE_HTTPS=0 \
    --from-literal=S3_VERIFY_SSL=0 \
    --from-literal=AWS_S3_FORCE_PATH_STYLE=true \
    --dry-run=client -o yaml | oc apply -f -
  oc annotate secret minio-s3 -n "${ns}" --overwrite \
    "serving.kserve.io/s3-endpoint=minio.minio-system.svc:9000" \
    "serving.kserve.io/s3-usehttps=0" \
    "serving.kserve.io/s3-region=us-east-1" \
    "serving.kserve.io/s3-verifyssl=0" \
    "serving.kserve.io/s3-useanoncredential=false" \
    "serving.kserve.io/s3-usevirtualbucket=false"
done

for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_BUILD_IMAGE}" "${NS_MODEL_TEST}"; do
  oc create secret docker-registry "${QUAY_SECRET_NAME}" \
    --docker-server="${QUAY_SERVER}" \
    --docker-username="${QUAY_USERNAME}" \
    --docker-password="${QUAY_PASSWORD}" \
    --docker-email="${QUAY_EMAIL}" \
    -n "${ns}" \
    --dry-run=client -o yaml | oc apply -f -
done

oc secrets link builder "${QUAY_SECRET_NAME}" -n "${NS_BUILD_IMAGE}"

oc create secret generic hf-token -n "${NS_MODEL_INGRESS}" \
  --from-literal=HF_TOKEN="${HF_TOKEN}" \
  --dry-run=client -o yaml | oc apply -f -

# =============================================================================
# Phase 3: Build scanner images (Binary BuildConfigs from overlay 06)
# =============================================================================
# Wait until ai-sec-06-builds is Synced before starting builds:
#   oc get application ai-sec-06-builds -n "${NS_GITOPS}"
for bc in model-fetch static-scan dynamic-test capability-eval adversarial-test score-gate publish; do
  oc start-build "ai-security-${bc}" --from-dir="builds/${bc}" --follow -n "${NS_BUILD_IMAGE}"
done

oc get istag -n "${NS_BUILD_IMAGE}" | grep ai-security

for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}"; do
  oc policy add-role-to-group system:image-puller "system:serviceaccounts:${ns}" -n "${NS_BUILD_IMAGE}"
done

# =============================================================================
# Phase 4: Authorino serving-cert annotate
# =============================================================================
oc annotate svc/authorino-authorino-authorization \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  -n kuadrant-system --overwrite || true

# =============================================================================
# Phase 5: Test serving (overlay 16 — not an Argo app; gitignored generated files)
# =============================================================================
export MODEL_CONN_VERSION="${MODEL_CONN_VERSION:-d4xs2}"
export MODEL_CONN_NAME="redhatai-qwen3-8b-fp8-dynamic-${MODEL_CONN_VERSION}"

python3 - <<'PY'
from pathlib import Path
import os
ver = os.environ["MODEL_CONN_VERSION"]
user = os.environ["MINIO_ROOT_USER"]
password = os.environ["MINIO_ROOT_PASSWORD"]
conn = Path("instances/model-test/model-connection-secret.yaml.template").read_text()
conn = conn.replace("PLACEHOLDER", ver)
conn = conn.replace("CHANGE_ME_MINIO_ROOT_USER", user)
conn = conn.replace("CHANGE_ME_MINIO_ROOT_PASSWORD", password)
Path("instances/model-test/model-connection-secret.yaml").write_text(conn)
llmis = Path("instances/model-test/qwen3-8b-fp8-verified.yaml.template").read_text()
Path("instances/model-test/qwen3-8b-fp8-verified.yaml").write_text(
    llmis.replace("PLACEHOLDER", ver)
)
PY

oc apply -k ./overlays/16-test-serving/ -n "${NS_MODEL_TEST}"
oc get llminferenceservice -n "${NS_MODEL_TEST}"

# =============================================================================
# Phase 6: Fetch model + live PipelineRun (optional)
# =============================================================================
# oc apply -f ./instances/model-ingress-fetch/model-fetch-job.yaml -n "${NS_MODEL_INGRESS}"
# oc wait --for=condition=complete job/model-fetch -n "${NS_MODEL_INGRESS}" --timeout=7200s
#
# Edit git-url in pipelinerun-example.yaml first, then:
# oc create -f ./instances/tekton-pipeline/pipelinerun-example.yaml -n "${NS_MODEL_EVAL}"
# oc get pipelinerun -n "${NS_MODEL_EVAL}" -w

# =============================================================================
# Cleanup — uncomment only when tearing down
# =============================================================================
# oc delete application ai-model-security-platform -n "${NS_GITOPS}"
# oc delete applications -n "${NS_GITOPS}" -l app.kubernetes.io/part-of=ai-model-security-pipeline
# oc delete -k ./overlays/16-test-serving/ -n "${NS_MODEL_TEST}"
