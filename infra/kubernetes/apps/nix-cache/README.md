# nix-cache: niks3 on can-1

CI's Nix binary cache. See `design/specs/2026-11-20-nix-ci-checks-design.md`.

| | |
| --- | --- |
| Read URL (substituter) | `https://cache.mydia.dev` (R2 bucket `mydia-nix-cache`, custom domain) |
| Public key | `cache.mydia.dev-1:5zkoQR4Gcrx1EEQ1GvHRPQ7EoHm8gNrrVoeAqX3ioFg=` |
| Write URL | `https://niks3.mydia.dev` (this namespace) |
| Write auth | GitHub OIDC, audience `https://niks3.mydia.dev`, `repo:getmydia/mydia:*` |

niks3 is a write coordinator. Clients get presigned URLs from it and upload
NARs straight to R2; it records references in PostgreSQL so the daily GC
CronJob can reclaim closures older than 14 days that are not pinned. Reads
never touch can-1, so a can-1 outage stops pushes but not substitution.

`niks3.mydia.dev` must stay grey-cloud (`cloudflare-proxied: "false"` on the
IngressRoute). Proxied, Cloudflare serves GitHub runners a managed challenge
and pushes fail.

## Files

- `niks3-values.yaml`: values for niks3's upstream Helm chart.
- `niks3.yaml`: rendered from the chart by `./render.sh`. Do not hand-edit; change
  the values (or the pinned tag in `render.sh`) and re-render.
- `postgres.yaml`: the reference database. It holds GC bookkeeping and pins
  only, no NAR data.
- `ingress.yaml`: certificate, IngressRoute and the DNS record (via external-dns).

Apply with `kubectl --context k3s-can1 apply -k infra/kubernetes/apps/nix-cache`.

## Secrets (created by hand, not in git)

| Secret | Keys | Source |
| --- | --- | --- |
| `niks3-db` | `password`, `uri` | random; `uri` is `postgres://niks3:<password>@niks3-postgres.nix-cache.svc:5432/niks3?sslmode=disable` |
| `niks3-token` | `token` | random 64 hex chars; admin token for GC and manual pushes |
| `niks3-s3` | `access-key`, `secret-key` | Cloudflare account API token "niks3 mydia-nix-cache (can-1)", R2 bucket item write on `mydia-nix-cache` only. Access key is the token id, secret is the SHA-256 of the token value |
| `niks3-signing` | `cache.mydia.dev-1` | `nix key generate-secret --key-name cache.mydia.dev-1` |

The signing key exists only in the cluster. If it is lost, generate
`cache.mydia.dev-2`, add its public key next to the old one in CI's
`extra-trusted-public-keys`, and drop the old one once its paths have aged out.

## Checks

```bash
curl -s https://cache.mydia.dev/nix-cache-info
curl -s https://niks3.mydia.dev/healthz
kubectl --context k3s-can1 -n nix-cache logs deploy/niks3
```
