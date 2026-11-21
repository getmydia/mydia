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

## Who can write, and why that is accepted

This is a deliberate decision, not an oversight. niks3 signs every path it
is handed with `cache.mydia.dev-1`, and CI treats a check whose output is
already in the cache as passed, so whoever can upload can make a check
pass on master without running it. Two kinds of caller can upload:

- any workflow run in `getmydia/mydia` that obtains a GitHub OIDC token for
  the niks3 audience (the server accepts `repo:getmydia/mydia:*`). That
  includes a pull request from a branch of this repository whose workflow
  was edited in the same PR: its run gets `id-token: write` like any other
  same-repo run;
- any holder of the `niks3-token` admin token (GC, and manual pushes with
  `scripts/nix-cache-push.sh`).

This is acceptable because write access to the repository, which is what
it takes to push a branch or read the admin token, is held by a small,
trusted set of maintainers who could change the checks themselves anyway.
Pull requests from forks cannot write: GitHub gives their runs no OIDC
token, so they only read the cache. Widen write access to the repository
only after revisiting this boundary. CI's side of it: `nix/ci/README.md`,
"Who can write to the cache".

## Files

- `niks3-values.yaml`: values for niks3's upstream Helm chart.
- `niks3.yaml`: rendered from the chart by `./render.sh`. Do not hand-edit; change
  the values (or the pinned niks3 commit in `render.sh`) and re-render.
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

The signing key exists only in the cluster. If it is lost, rotate to
`cache.mydia.dev-2` on both sides:

1. Server: `nix key generate-secret --key-name cache.mydia.dev-2`, store it
   in `niks3-signing` under the key `cache.mydia.dev-2`, set `signing.keys`
   to `[cache.mydia.dev-2]` in `niks3-values.yaml`, re-render `niks3.yaml`
   with `./render.sh` (the Deployment's `--sign-key-path` follows
   `signing.keys`) and apply. Until then niks3 keeps signing with the
   lost key's file, or fails to start without it.
2. Clients: derive the public key (`nix key convert-secret-to-public`) and
   add it next to the old one everywhere `cache.mydia.dev-1:` is trusted
   (`grep -rn 'cache.mydia.dev-1:'`: the nix-ci action,
   `scripts/nix-cache-push.sh`, `scripts/ci-restore-test-build.sh`,
   `.github/ci.md`). Drop the old key once its paths have aged out.

## Checks

```bash
curl -s https://cache.mydia.dev/nix-cache-info
curl -s https://niks3.mydia.dev/healthz
kubectl --context k3s-can1 -n nix-cache logs deploy/niks3
```
