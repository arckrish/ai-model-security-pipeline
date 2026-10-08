# model-sandbox

Persistent namespace for **untrusted** eval serving. The pipeline does not create or delete this namespace.

| Applied by | Files |
|------------|--------|
| Overlay 04 / `oc apply -k` (once) | namespace, NetworkPolicy, RBAC |
| `serve-llm-start` | `LLMInferenceService.yaml` — placeholder image → `oci://…:unverified` |
| `serve-llm-stop` | Deletes the CR only |

Quay pull secret must exist in this namespace (gitops-scripts Phase 2) so KServe can pull the ModelCar image.
