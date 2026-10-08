# Test zone — verified model serving after pipeline pass

All serving manifests live in this directory (no subfolders).

- **Phase 2 (overlay `04-zones`):** `namespace.yaml` via `overlays/04-zones/model-test/`
- **Overlay `16-test-serving`:** network policies, RBAC, `LLMInferenceServiceConfig`
- **Verified `LLMInferenceService`:** applied by `publish-artifact` (not kustomize)

## ModelCar + placeholder image

Committed example: [`qwen3-8b-fp8-verified.yaml`](qwen3-8b-fp8-verified.yaml) with `spec.model.uri: oci://PLACEHOLDER`.

PipelineRun params:

- `model-id` / `modelcar-image` — must match the model-fetch Job
- `serving-yaml` — path to this file (or another model’s YAML)

On auto-pass / review, `publish-artifact`:

1. Retags ModelCar `:unverified` → `:verified-score-build<VERSION>`
2. Registers Model Registry with `oci://…`
3. Replaces **only** the placeholder URI in `serving-yaml` and `oc apply`s it in `model-test`

No `.yaml.template` and no rewriting of names or ODH connection annotations.

## Smoke test

```bash
GATEWAY_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
GATEWAY_URL="https://${GATEWAY_HOST}/model-test/qwen3-8b-fp8"
TOKEN="$(oc create token test-user -n model-test)"

curl -sS "${GATEWAY_URL}/v1/models" -H "Authorization: Bearer ${TOKEN}" | jq .
```

Ensure Quay pull secrets exist in `model-test` (gitops-scripts Phase 2) so the verified ModelCar can be pulled.
