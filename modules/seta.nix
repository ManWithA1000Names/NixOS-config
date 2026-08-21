{ lib, DOMAIN, ... }: {
  options.seta = lib.mkOption {
    default = { };
    description = "Service mETA data.";

    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }: {
          options = {
            dashboard = lib.mkOption {
              default = { };

              description = "Options for including this service in the homepage-dashboard.";

              type = lib.types.submodule {
                options = {
                  enable = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "Enable inclusion in the homepage-dashboard.";
                  };

                  name = lib.mkOption {
                    type = lib.types.str;
                    default = name;
                    description = "The name shown for the service in the homepage-dashboard";
                  };

                  group = lib.mkOption {
                    type = lib.types.str;
                    default = "General";
                    description = "The logical group/category this service belongs to.";
                  };

                  icon = lib.mkOption {
                    type = lib.types.str;
                    default = "";
                    description = "The icon that should be used for the service.";
                  };

                  description = lib.mkOption {
                    type = lib.types.str;
                    default = "";
                    description = "A short description of what this service is/does.";
                  };
                };
              };
            };

            proxy = lib.mkOption {
              default = { };

              description = "Options for proxying and exposing this service.";

              type = lib.types.submodule {
                options = {
                  enable = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "Enable the proxying behaviour.";
                  };

                  port = lib.mkOption {
                    type = lib.types.port;
                    description = "Internal service port.";
                  };

                  domain = lib.mkOption {
                    type = lib.types.str;
                    default = "${name}.${DOMAIN}";
                    description = ''
                      The sub-domain that will be used in the proxy.

                      Must stay a single label under ''${DOMAIN}: the managed
                      wildcard certificate is `*.''${DOMAIN}`, and a wildcard
                      matches exactly one label. A name like `a.b.''${DOMAIN}`
                      evaluates fine but makes caddy issue a separate
                      certificate for it, publishing the name to the CT logs.
                    '';
                  };

                  config = lib.mkOption {
                    type = lib.types.str;
                    default = "";
                    description = "Custom caddy configuration for the service.";
                  };

                  # Deliberately has no default: a service that does not state
                  # its exposure would otherwise silently get the most
                  # restrictive hardening, look broken, and be "fixed" by
                  # loosening something else.
                  exposure = lib.mkOption {
                    type = lib.types.enum [
                      "NONE"
                      "LAN"
                      "WAN"
                    ];
                    description = "The hardening, scrutiny and exposure level that should be applied to this service.";
                  };
                };
              };
            };
          };
        }
      )
    );
  };
}
