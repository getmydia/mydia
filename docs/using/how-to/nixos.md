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

## Features

The NixOS module supports:

- OIDC authentication configuration
- Download client setup
- FlareSolverr integration
- Systemd security hardening
- Secrets management via files

See [docs/nix.md](https://github.com/getmydia/mydia/blob/master/docs/nix.md) in the repository for complete configuration options.
