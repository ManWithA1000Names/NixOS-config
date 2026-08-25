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

                  headers = lib.mkOption {
                    type = lib.types.attrsOf lib.types.str;
                    default = { };
                    description = "Request headers forwarded upstream (header_up Name Value).";
                  };

                  removeHeaders = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    description = "Request headers stripped before reaching the upstream (header_up -Name).";
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

            # Every systemd unit this service owns. Defaults to just the
            # service's own name, which is right for most of them -- but some
            # bring adjacent units along (vaultwarden has backup-vaultwarden,
            # paperless has a scheduler and consumer), and the flags below all
            # need to act on the *units*, not on the seta entry.
            #
            # Having one list feed both requiresExSSD and critical is what lets
            # those two stay plain booleans: "critical, and also these extra
            # units" is expressible without either flag growing a list type.
            units = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ name ];
              description = "Every systemd unit this service owns.";
            };

            requiresExSSD = lib.mkOption {
              default = false;

              description = ''
                Does this service or any related service/s depend on the
                external ssd being mounted?

                Applies RequiresMountsFor to every unit in `units`, so a
                service with adjacent units is all-or-nothing: none of them
                start when the drive is absent.
              '';

              type = lib.types.bool;
            };

            postgres = lib.mkOption {
              default = false;

              description = ''
                Does this service keep its state in the centralized postgres?

                Creates a database and a role, both named after the service,
                with the role owning the database. Authentication is peer over
                the unix socket, so the role name must match the system user
                the service runs as -- which is the case for every service
                here, including the DynamicUser ones.

                Safe to set even when the service's own nixpkgs module already
                declares the same database (mealie, paperless and gitea all
                do): ensureDatabases/ensureUsers are generated as
                `SELECT 1 ... || CREATE`, so a duplicate entry is a no-op.

                Doubles as the manifest for the backup job -- the point of
                centralizing was to have one thing to dump.
              '';

              type = lib.types.bool;
            };

            critical = lib.mkOption {
              default = false;

              description = ''
                Does this service qualify as being 'critical'? Wires every unit
                in `units` to the telegram notifier via OnFailure.

                Deliberately a plain bool rather than `bool | listOf str`: the
                list form made every consumer branch on the type, and could not
                name extra units without repeating the service name. Extra
                units go in `units` instead.
              '';

              type = lib.types.bool;
            };
          };
        }
      )
    );
  };
}
