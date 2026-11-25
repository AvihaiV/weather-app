# Guide for the junior developer and the junior DevOps engineer

These are short rules, and each one has a reason. When a rule gets in your way, ask before working around it: most of them exist because something went wrong once.

## Both of you
- **Never commit a secret.** That covers passwords, tokens, kubeconfigs, `.env` files, `terraform.tfstate` and `*.tfvars`. `.gitignore` covers the usual files. Install the local hook too:
  ```bash
  printf '#!/bin/sh\nexec gitleaks git --staged --no-banner --redact .\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
  ```
  CI scans the full history again on every push.
- **Small PRs, green CI, then merge.** Only commits whose whole pipeline passed get deployed, so a red `main` blocks everyone.
- **Never use `--no-verify`**, and never disable a check to make CI green. Fix the cause, or add a skip **with a written reason** next to it (see `infra/.checkov.yaml`).

## Junior developer: changing the app safely
- **The API is read-only.** A new endpoint is `GET`, validates every input (see the city allow-list and the `hours` range in `api.py`), and returns a generic error, never a stack trace or SQL error.
- **SQL:** always parameters (`%s`), never f-strings or string concatenation.
- **Frontend:** write data with `textContent`, never `innerHTML`. A new external script or style would break the CSP in `nginx.conf`. That is intentional, so ask first.
- **External APIs are untrusted input.** Validate before storing (see `collector.parse`). Retry only 429/5xx, with backoff (see `_get_json`).
- **Every change gets a test** in `app/backend/tests`. Run `make test`; it takes seconds.
- **Schema changes are additive** (`ADD COLUMN ... IF NOT EXISTS`). The migrate hook runs before new pods start, so old pods must still work with the new schema during a rollout.
- **Dependencies:** pin the exact version in `requirements.txt`. `pip-audit` fails CI on known CVEs.

## Junior DevOps: changing workloads safely
- **Change the chart, not the cluster.** Everything is in `deploy/helm/weather`. Anything done with `kubectl edit` is lost on the next deploy and leaves no review trail.
- **New workload checklist:**
  - its own ServiceAccount with `automountServiceAccountToken: false`
  - the restricted `securityContext` (copy from `_helpers.tpl`)
  - CPU/memory requests and limits, plus readiness and liveness probes
  - a NetworkPolicy allowing **only** the connections it needs; the default is deny
  - ≥2 replicas and a PDB if users depend on it
- **Images:** reference only immutable `sha-<commit>` tags. Never `latest`.
- **Check before you push:**
  ```bash
  helm lint deploy/helm/weather -f deploy/helm/weather/values-local.yaml
  terraform fmt -recursive infra
  ```
  Then `make local-up` and `scripts/smoke-test.sh` when you change something that runs.
- **Terraform on a real environment:** always read `plan` before `apply`. Never kill an `apply` halfway: it can leave Helm releases stuck in `pending-upgrade`. CI deploys to a persistent environment must never auto-cancel.
- **Don't weaken a control to make something work.** Examples: opening a NetworkPolicy to `0.0.0.0/0`, running as root, adding `privileged`. Find which control blocks you (`kubectl describe`, events) and allow exactly that.

## Troubleshooting CI
| Failing job | Usually means | Do |
|---|---|---|
| Unit tests / pip-audit | a test broke, or a dependency has a new CVE | run `make test`; bump the pinned version that pip-audit names |
| Secret scan | gitleaks found a secret **in history** | treat it as a leak (next section), not as a lint error |
| IaC: terraform fmt | formatting | `terraform fmt -recursive infra` |
| IaC: Checkov | a new risky setting | fix it; skip only with a reason |
| IaC: kubeconform | invalid manifest, often an unquoted value (`y`, `on` and `yes` become booleans) | quote it in the template |
| Trivy image | a fixable HIGH/CRITICAL CVE in the image | rebuild (base images have `apt/apk upgrade`), or bump the base digest |
| Deploy + smoke tests | the app or a control is broken | read the "Diagnostics on failure" step: pod status, events, logs |
| Smoke test `WARN weather API unavailable` | Open-Meteo is down or rate-limiting the shared runner IP | not our bug; history still comes from the backfill. Rerun later |
| Run shows **cancelled** | a newer push replaced it | expected; look at the newest run |

To read logs from the terminal:
```bash
gh run view <id> --log-failed
```

## If a credential leaks
A secret that reached GitHub is **compromised**, even if it was there for a minute and even if the repo is private. Order matters:
1. **Revoke or rotate it first.** Deleting the commit does not help: forks, caches and clones already have it. For a kubeconfig, recreate the cluster or rotate its CA. For a cloud key, deactivate it. For a DB password, change it.
2. **Check whether it was used:** CloudTrail, the API server audit log, DB logs, from when it leaked until it was revoked.
3. **Remove it from history** (`git filter-repo`), force-push, and ask GitHub support to purge cached views if needed. This step is cleanup, not a fix.
4. **Close the gap that let it through:** `.gitignore`, the pre-commit hook, moving the file out of the repo.
5. **Write it down:** what leaked, how, for how long, what you did.

This happened here once: a kind kubeconfig was pushed because a pipe hid gitleaks' exit code. The cluster was recreated to rotate the key, the kubeconfig moved to `~/.kube`, the history was rewritten and a pre-commit hook was added.

The best fix is to have **nothing to leak**. CI uses OIDC and pods use Pod Identity or generated secrets, so no long-lived keys exist to be committed.

## If a deploy was interrupted
On kind/CI: ignore it. The runner and the cluster are gone. On a persistent environment, **inspect before you retry**. Never just rerun it.

### Terraform apply
1. **Is anyone else running?** Check the Actions tab and ask the team. Only then run `terraform force-unlock <LOCK_ID>` (the ID is in the "Error acquiring the state lock" message).
2. **Compare reality with state.** List what really exists in AWS, by tags or names in the console or CLI, and compare it with `terraform state list` and `terraform plan`.
   - **A create in the plan for something that already exists** means the resource is untracked: the apply was killed before state was saved. `import` it (or use an `import {}` block), or delete it by hand if it is truly unwanted.
   - **A resource marked tainted** means the creation failed and Terraform recorded it. The plan will replace it. Confirm the replacement is acceptable: replacing a database is not.
   - **Don't assume either case.** Check each resource.
3. **State file damaged?** Restore the previous version from the versioned S3 state bucket.
4. **Apply again** from a fresh plan, reviewed, and write down what happened.

### Helm release
1. **Look at the release first:**
   ```bash
   helm -n <ns> status <release>
   helm -n <ns> history <release>
   ```
2. **`pending-upgrade`, with an earlier `deployed` revision:** roll back to that revision with `helm -n <ns> rollback <release> <revision>`, then deploy again.
3. **`pending-install`, a first install with nothing to roll back to:**
   - The only way out is `helm uninstall` and then install again. Before that, check what the release owns.
   - The **app chart owns no data**: the database is a separate release, or RDS on AWS. Uninstalling it is safe, apart from the downtime.
   - **A release that owns data is different.** The `weather-db` chart owns the CloudNativePG `Cluster`, so uninstalling it can delete the database. Back up first, or fix the release record instead of uninstalling.
4. **If Terraform manages the release** (as in `infra/local`), also run `terraform state rm` for it after an uninstall, so the next apply recreates it cleanly.

## Useful commands
```bash
export KUBECONFIG=~/.kube/kind-weather
kubectl -n weather get pods,jobs,cronjobs
kubectl -n weather logs deploy/weather-backend
kubectl -n weather-db get cluster weather-db     # CloudNativePG status, current primary
kubectl get events -A --sort-by=.lastTimestamp | tail -20
```
