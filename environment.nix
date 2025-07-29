{ lib, plane_app_port, plane_app_domain, ... }:
{
  # By default nix has some aliases that need to go.
  environment.shellAliases = lib.mkForce { };

  environment.variables = {
    PLANE_APP_PORT = plane_app_port;
    PLANE_WEB_URL = "http://${plane_app_domain}";
  };
}
