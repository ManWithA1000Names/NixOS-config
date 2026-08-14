{ config, pkgs, MEDIA_GROUP, DOMAIN, ... }@args:
let
  HOMELAB_DASHBOARD_PORT = 8000;
  toDomain = sub: "${sub}.${DOMAIN}";
  config_args = { inherit toDomain MEDIA_GROUP; };

  all_services = [
    (import ./services/gitea.nix)
    (import ./services/jellyfin.nix)
    (import ./services/kavita.nix)
    (import ./services/mealie.nix)
    (import ./services/paperless.nix)
    (import ./services/vaultwarden.nix)

    # -- RR stack services
    (import ./services/arr/bazarr.nix)
    (import ./services/arr/prowlarr.nix)
    (import ./services/arr/qbittorrent.nix)
    (import ./services/arr/radarr.nix)
    (import ./services/arr/seerr.nix)
    (import ./services/arr/sonarr.nix)
  ];
in (import ./arr-media-stack-tweaks.nix args) // (
  #
  # Assert that all service ports are unique.
  #
  assert (builtins.foldl' (ports: service:
    assert !builtins.hasAttr (builtins.toString service.PORT) ports;
    {
      ${builtins.toString service.PORT} = true;
    } // ports) { ok = true; } all_services).ok;
  #
  # Define the actual services.<name> options.
  #
  {

    services = {
      openssh = {
        enable = true;
        settings = {
          PermitRootLogin = "no";
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
        };
      };

      caddy = {
        enable = true;

        # Stock caddy has no DNS provider modules compiled in; the ACME DNS-01
        # challenge below is unusable without this plugin.
        package = pkgs.caddy.withPlugins {
          plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
          hash = "sha256-7GoH8YLCoPmPExQxoga2FHB58zQDoZVf1BBwkVi0SsQ=";
        };

        # Read by systemd before the caddy process starts. Must define
        # CF_API_TOKEN (single Cloudflare token: Zone.Zone:Read + Zone.DNS:Edit).
        environmentFile = config.age.secrets.cloudflare-dns-api.path;

        # DNS-01 rather than HTTP-01 because the wildcard below cannot be
        # validated any other way.
        globalConfig = ''
          acme_dns cloudflare {env.CF_API_TOKEN}
          tls_resolvers 1.1.1.1
        '';

        virtualHosts = (builtins.foldl' (hosts: service:
          {
            ${toDomain service.SUB-DOMAIN}.extraConfig =
              if service ? "CADDY_EXTRA_CONFIG" then
                service.CADDY_EXTRA_CONFIG
              else
                "reverse_proxy localhost:${builtins.toString service.PORT}";
          } // hosts) { } all_services) // {
            ${DOMAIN}.extraConfig = "reverse_proxy localhost:${
                builtins.toString HOMELAB_DASHBOARD_PORT
              }";

            # Exists purely so caddy manages a wildcard cert. Caddy skips
            # per-name certs for any subject a managed wildcard covers, so all
            # service hosts above share this one cert. Exact hosts still win
            # at routing time; this only catches subdomains with no service.
            "*.${DOMAIN}".extraConfig = "respond 404";
          };
      };

      homelab-dashboard = {
        enable = true;
        port = HOMELAB_DASHBOARD_PORT;
        title = "Local Cloud Control Center";
        services = builtins.foldl' (services: service:
          {
            ${service.SUB-DOMAIN} = {
              url = "https://${toDomain service.SUB-DOMAIN}";
              name = service.NAME;
            };
          } // services) { } all_services;
      };
    } // (builtins.foldl' (configs: service:
      {
        ${service.SERVICE} = service.config config_args;
      } // configs) { } all_services);
  })
