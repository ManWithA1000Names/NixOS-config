{
  config,
  lib,
  DOMAIN,
  IP,
  ...
}:
{
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

            networkConfinement = lib.mkOption {
              default = { };

              description = ''
                Hold this service to the egress proxy instead of trusting it to
                honour HTTP_PROXY.

                systemd.globalEnvironment (networking.nix) points every unit at
                tinyproxy, but that is a setting a service reads, not a route it
                is bound to -- a service that ignores the variables egresses
                directly and the proxy log never sees it. Applying
                IPAddressDeny/IPAddressAllow to every unit in `units` removes
                the alternative, so the proxy becomes the only path off the host
                that exists.

                On by default. The services that cannot take it are the ones
                whose traffic is not HTTP at all, and they say so explicitly --
                see qbittorrent (services-internal.nix) and mailpit (mail.nix).
              '';

              type = lib.types.submodule {
                options = {
                  enable = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = ''
                      Deny this service every route off the host except `allow`.

                      Defaulting to true rather than false is deliberate and is
                      the opposite of how `exposure` is handled: a service that
                      forgets to declare this gets the *safe* answer, and the
                      failure mode is a service that visibly cannot reach
                      something rather than one quietly egressing unobserved.
                    '';
                  };

                  allow = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [
                      "localhost"
                      IP.lan
                    ];
                    description = ''
                      Peer addresses this service may still reach, and be
                      reached from. Setting this replaces the default rather
                      than adding to it, so an extending service repeats the two
                      entries below.

                      `localhost` is systemd's own alias for 127.0.0.0/8 plus
                      ::1, which covers tinyproxy outbound, caddy's inbound
                      reverse-proxy connection, the systemd-resolved stub and
                      the PostgreSQL socket's TCP twin. Unix sockets are not
                      address-filtered at all, so socket-based collectors and
                      peer-auth database connections are unaffected either way.

                      IP.lan is the /24 and not IP.o700/32, because this filter
                      matches the *peer* address in both directions. Outbound it
                      is what lets netdata's x509check reach the names caddy
                      serves on this host's LAN address; inbound it is what lets
                      house clients reach jellyfin at all. Narrowed to a single
                      /32 the inbound half would black-hole every device on the
                      network.

                      Nothing here weakens the egress goal: LAN peers are not
                      the internet, and the only route past this list is
                      tinyproxy on loopback.
                    '';
                  };
                };
              };
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

  # Every name in `units` must be a unit that something actually defines.
  #
  # This exists because the failure mode is silent and has already happened
  # twice. `units` defaults to [ name ], which is wrong whenever the upstream
  # module names its units differently -- paperless ships four units and no
  # bare `paperless`, mailpit names its units after the instance. In both cases
  # every consumer here hangs its config off a unit that does not exist, and
  # systemd's module system is happy to synthesise an empty one, so critical
  # stops notifying, requiresExSSD stops gating and networkConfinement stops
  # confining, all without a single error.
  #
  # The check is for ExecStart rather than mere presence, and that distinction
  # is the whole point: the consumers *themselves* create the attribute. By the
  # time this runs, networking.nix has already written
  # systemd.services.mailpit.serviceConfig, so `? "mailpit"` is true even when
  # no such service exists. A real unit has a command to run; a synthesised one
  # has only whatever we hung off it. One check covers both spellings of that
  # command, because the submodule turns `script` into serviceConfig.ExecStart
  # (nixos/lib/systemd-unit-options.nix:497-503).
  #
  # A unit that legitimately has no ExecStart -- ExecStop-only, or a target --
  # would be a false positive. None exist here, and the fix would be to name a
  # real unit anyway.
  config.assertions = lib.concatLists (
    lib.mapAttrsToList (
      svc: meta:
      map (unit: {
        assertion = (config.systemd.services.${unit} or null) ? serviceConfig.ExecStart;
        message = ''
          seta.${svc}.units names "${unit}", which is not a systemd service defined by this
          configuration. Check what the upstream module actually calls its units and set
          seta.${svc}.units explicitly -- leaving it at the default of [ "${svc}" ] silently
          disables critical, requiresExSSD and networkConfinement for this service.
        '';
      }) meta.units
    ) config.seta
  );
}
