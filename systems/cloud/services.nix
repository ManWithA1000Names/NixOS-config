{ pkgs, MEDIA_GROUP, DOMAIN, ... }@args:
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
          };
      };

      homelab-dashboard = {
        enable = true;
        port = HOMELAB_DASHBOARD_PORT;
        title = "Local Cloud Control Center";
        services = builtins.foldl' (services: service:
          {
            ${services.SUB-DOMAIN} = {
              url = "https://${toDomain services.SUB-DOMAIN}";
              name = service.NAME;
            };
          } // services) { } all_services;
      };
    } // (builtins.foldl' (configs: service:
      {
        ${service.SERVICE} = service.config config_args;
      } // configs) { } all_services);
  })
