{ lib, ... }:
let shared = import ../shared.nix;
in {
  # By default nix has some aliases that need to go.
  environment.shellAliases = lib.mkForce { };

  environment.variables = {
    PLANE_APP_PORT = shared.plane_app_port;
    PLANE_WEB_URL = "http://${shared.plane_app_domain}";
  };
}
