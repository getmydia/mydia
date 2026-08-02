# NixOS Deployment

This guide covers deploying Mydia declaratively on NixOS using the provided flake and module.

## Flake Configuration

```nix
# flake.nix
{
  inputs.mydia.url = "github:getmydia/mydia";

  outputs = { self, nixpkgs, mydia }: {
    nixosConfigurations.myserver = nixpkgs.lib.nixosSystem {
      modules = [ mydia.nixosModules.default ./configuration.nix ];
    };
  };
}
```

## Module Configuration

```nix
# configuration.nix
{
  services.mydia = {
    enable = true;
    host = "mydia.example.com";
    secretKeyBaseFile = "/run/secrets/mydia/secret_key_base";
    guardianSecretKeyFile = "/run/secrets/mydia/guardian_secret_key";
    mediaLibraries = [ "/mnt/media/movies" "/mnt/media/tv" ];
  };
}
```

## Module Options

Every option lives under `services.mydia`.

### Core

| Option | Type | Default | Purpose |
|---|---|---|---|
| `enable` | bool | `false` | Turn the service on |
| `package` | package | the flake's | Which build to run |
| `host` | str | `"localhost"` | Public hostname, used for URL generation |
| `port` | port | `4000` | Web interface port |
| `listenAddress` | str | `"127.0.0.1"` | Bind address. Change it or put a proxy in front. |
| `dataDir` | path | `"/var/lib/mydia"` | Application data directory |
| `mediaLibraries` | list of paths | `[]` | Paths the service is granted read access to |
| `user` / `group` | str | `"mydia"` | Service account |
| `openFirewall` | bool | `false` | Open `port` in the firewall |
| `logLevel` | enum | `"info"` | `debug`, `info`, `warning`, or `error` |
| `extraEnvironment` | attrs of str | `{}` | Any environment variable not covered by an option |

`extraEnvironment` is the escape hatch: anything in
[Environment Variables](../reference/environment-variables.md) can be set through
it, including feature flags such as `ENABLE_REMOTE_ACCESS`.

### Secrets

| Option | Type | Purpose |
|---|---|---|
| `secretKeyBaseFile` | path | File containing `SECRET_KEY_BASE`. Required. |
| `guardianSecretKeyFile` | path or null | File containing `GUARDIAN_SECRET_KEY` |

Both are read from files rather than set inline, so secrets never land in the Nix
store.

### Database

| Option | Type | Default | Purpose |
|---|---|---|---|
| `database.type` | `"sqlite"` or `"postgres"` | `"sqlite"` | Backend. Must match the package variant. |
| `database.path` | path | `"/var/lib/mydia/mydia.db"` | SQLite file (sqlite only) |
| `database.host` | str | `"localhost"` | Postgres host |
| `database.port` | port | `5432` | Postgres port |
| `database.name` | str | `"mydia"` | Postgres database |
| `database.user` | str | `"mydia"` | Postgres user |
| `database.passwordFile` | path or null | `null` | Not needed with local peer auth |
| `database.createLocally` | bool | `true` | Provision a local PostgreSQL instance |
| `database.sslMode` | `"verify"` or `"disable"` | `"disable"` | Use `verify` for remote Postgres over SSL |

### OIDC

| Option | Type | Default | Purpose |
|---|---|---|---|
| `oidc.enable` | bool | `false` | Turn on SSO |
| `oidc.issuer` | str | required | Issuer URL |
| `oidc.discoveryDocumentUri` | str or null | derived from issuer | Override the discovery document |
| `oidc.clientIdFile` | path | required | File containing the client ID |
| `oidc.clientSecretFile` | path | required | File containing the client secret |
| `oidc.scopes` | list of str | `[ "openid" "profile" "email" ]` | Requested scopes |

See [SSO / OIDC](sso-oidc.md) for provider setup, and note the redirect URI
caveat there if you are not serving Mydia over https.

### Download clients

`downloadClients` is an attribute set. Each entry takes `type`, `host`, `port`,
`username`, `passwordFile`, and `useSsl`:

```nix
services.mydia.downloadClients = {
  main = {
    type = "qbittorrent";
    host = "localhost";
    port = 8080;
    username = "admin";
    passwordFile = "/run/secrets/mydia/qbittorrent_password";
  };
};
```

### FlareSolverr

| Option | Type | Default |
|---|---|---|
| `flareSolverr.enable` | bool | `false` |
| `flareSolverr.url` | str | `"http://localhost:8191"` |
| `flareSolverr.timeout` | int | `60000` |
| `flareSolverr.maxTimeout` | int | `120000` |

## Worked Examples

The repository carries three complete configurations you can copy:
[`minimal.nix`](https://github.com/getmydia/mydia/blob/master/examples/nixos/minimal.nix),
[`full.nix`](https://github.com/getmydia/mydia/blob/master/examples/nixos/full.nix),
and
[`with-oidc.nix`](https://github.com/getmydia/mydia/blob/master/examples/nixos/with-oidc.nix).
The module itself is
[`nix/module.nix`](https://github.com/getmydia/mydia/blob/master/nix/module.nix),
which is the authoritative option list if this page ever falls behind.

## Next Steps

- [Managing Libraries](manage-libraries.md) - Point Mydia at the paths you listed in `mediaLibraries`
- [Reverse Proxy](reverse-proxy.md) - Put TLS in front of `listenAddress`
- [Backing Up and Restoring](backup-restore.md) - The unit copies the SQLite database before migrating, nothing backs up the rest of `dataDir` for you
- [Monitoring and Logs](monitor-and-logs.md) - Where to look when the unit misbehaves
