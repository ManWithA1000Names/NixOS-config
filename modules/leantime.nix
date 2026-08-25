{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.leantime;

  # Leantime publishes a *built* release tarball: composer's vendor/ and the
  # laravel-mix output (public/dist + mix-manifest.json) are already inside it.
  # So this is a fetch-and-unpack, not a build -- no gemset, no vendorHash, no
  # npmDepsHash, nothing generated to keep in sync. A version bump is one URL
  # and one hash.
  #
  # This is the whole reason to prefer a native module here over the nixpkgs PR
  # (#487681), which builds the same artifact from source via
  # buildComposerProject2 + buildNpmPackage and therefore carries two
  # fixed-output hashes that both have to be regenerated on every bump.
  package = pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "leantime";
    version = "3.9.8";

    src = pkgs.fetchurl {
      url = "https://github.com/Leantime/leantime/releases/download/v${finalAttrs.version}/Leantime-v${finalAttrs.version}.tar.gz";
      hash = "sha256-eXfwR37+yES2Z2djRasGsGl6HNE1KqaYmZrwGMLJnVI=";
    };

    # The tarball has no single top-level directory -- app/, vendor/, public/
    # and friends are all at the root -- so stdenv has nothing to descend into.
    sourceRoot = ".";

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/leantime
      cp -r ./. $out/share/leantime/

      # Leantime is a Laravel app and expects four paths to be writable. A store
      # path is not, so each is replaced by an absolute symlink into dataDir.
      #
      # This is deliberately NOT the approach the nixpkgs PR takes: it patches
      # Application.php and laravelConfig.php to read an APP_DATA_PATH env var.
      # Those patches are cut against 3.6.2 and carry unrelated reformatting
      # noise, so they conflict on almost every upstream release. Symlinks touch
      # no PHP at all and keep working across versions -- which is the property
      # actually being bought here.
      #
      # bootstrap/ is split rather than redirected wholesale: it holds app.php
      # (code, must stay in the store) alongside cache/ (Laravel's compiled
      # config and routes, must be writable). The PR's patch moves the whole
      # directory, which drags app.php out of the store with it.
      rm -rf $out/share/leantime/storage \
             $out/share/leantime/bootstrap/cache \
             $out/share/leantime/userfiles \
             $out/share/leantime/public/userfiles

      ln -s ${cfg.dataDir}/storage          $out/share/leantime/storage
      ln -s ${cfg.dataDir}/bootstrap-cache  $out/share/leantime/bootstrap/cache
      ln -s ${cfg.dataDir}/userfiles        $out/share/leantime/userfiles
      ln -s ${cfg.dataDir}/public-userfiles $out/share/leantime/public/userfiles

      runHook postInstall
    '';

    meta = {
      description = "Goals-focused project management system";
      homepage = "https://leantime.io";
      # AGPL, not GPL. Self-hosting an unmodified copy carries no obligation,
      # but patching it and exposing that over the network does: the modified
      # source has to be offered to users of the instance.
      license = lib.licenses.agpl3Only;
      platforms = lib.platforms.linux;
    };
  });

  phpPackage = cfg.phpPackage.buildEnv {
    extensions =
      { all, enabled }:
      enabled
      ++ (with all; [
        bcmath
        curl
        exif
        gd
        ldap
        mbstring
        opcache
        pdo
        pdo_mysql
        pdo_pgsql
        simplexml
        zip
      ]);

    extraConfig = ''
      memory_limit = ${cfg.memoryLimit}
      upload_max_filesize = ${cfg.maxUploadSize}
      post_max_size = ${cfg.maxUploadSize}
    '';
  };

  # Leantime reads configuration exclusively from the process environment --
  # LEAN_* variables, exactly as the upstream container does. It never writes a
  # config/.env, which is what lets config/ stay read-only in the store.
  toEnvValue =
    v:
    if builtins.isBool v then
      (if v then "true" else "false")
    else if builtins.isInt v then
      toString v
    else
      v;

  settings = lib.filterAttrs (_: v: v != null) (
    {
      LEAN_DB_DEFAULT_CONNECTION = cfg.database.type;
      LEAN_DB_HOST = cfg.database.host;
      LEAN_DB_PORT = cfg.database.port;
      LEAN_DB_DATABASE = cfg.database.name;
      LEAN_DB_USER = cfg.database.user;
      LEAN_APP_URL = cfg.appUrl;
    }
    // cfg.settings
  );
in
{
  options.services.leantime = {
    enable = lib.mkEnableOption "Leantime project management";

    package = lib.mkOption {
      type = lib.types.package;
      default = package;
      defaultText = lib.literalMD "Leantime release tarball, unpacked";
      description = "The Leantime package to run.";
    };

    phpPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.php83;
      defaultText = lib.literalExpression "pkgs.php83";
      description = ''
        PHP used to run Leantime. Upstream requires 8.2 or newer and their own
        container ships 8.3, so that is what this tracks.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "leantime";
      description = ''
        User the php-fpm pool runs as.

        With peer authentication this name *is* the database credential, so it
        has to match the postgres role. Changing it without changing the role
        breaks the database connection.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "leantime";
      description = "Group the php-fpm pool runs as.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/leantime";
      description = ''
        Mutable state: uploads, Laravel's storage tree and the compiled
        bootstrap cache. The store path symlinks into here, so moving this
        rebuilds the package.
      '';
    };

    appUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://leantime.example.org";
      description = ''
        Absolute external URL, scheme included.

        Pasted verbatim into generated links and emails, so a bare hostname
        produces relative-looking URLs that resolve against whatever host the
        client happened to use. Same reasoning as Mealie's BASE_URL.
      '';
    };

    memoryLimit = lib.mkOption {
      type = lib.types.str;
      default = "256M";
      description = "PHP memory_limit for the pool.";
    };

    maxUploadSize = lib.mkOption {
      type = lib.types.str;
      default = "20M";
      description = "Ceiling for uploaded attachments (upload_max_filesize and post_max_size).";
    };

    database = {
      type = lib.mkOption {
        type = lib.types.enum [
          "pgsql"
          "mysql"
        ];
        default = "pgsql";
        description = ''
          Database driver. PostgreSQL support is upstream-experimental, added in
          3.7.0 and fixed up in Leantime PR #3447; it is the default here
          because the alternative is standing up a second database engine.
        '';
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "/run/postgresql";
        description = ''
          Database host, or an absolute path to a unix socket *directory*.

          A leading slash is what selects socket transport: Laravel's Postgres
          connector passes this straight through to libpq as `host=`, and libpq
          treats a path as a socket directory. That in turn is what makes peer
          authentication work, so no password is needed or stored anywhere.

          UNVERIFIED. This is inference from libpq's documented behaviour, not
          something that has been observed working -- and it fails as an opaque
          authentication error rather than a clear one. Prove it before trusting
          it, the same way the seerr peer-auth note recommends:

            sudo -u leantime psql -h /run/postgresql -U leantime leantime

          If it does not hold, the fallback is a TCP host plus a password via
          `environmentFile`, which costs the no-passwords property.
        '';
      };

      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = ''
          Database port. Left null for socket connections, where libpq's
          compiled-in default selects the socket filename (.s.PGSQL.5432).
        '';
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "leantime";
        description = "Database name.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "leantime";
        description = "Database role. Must equal `user` for peer authentication.";
      };
    };

    pool = {
      listenOwner = lib.mkOption {
        type = lib.types.str;
        default = "caddy";
        description = ''
          Owner of the php-fpm listening socket -- i.e. the webserver, which is
          the only thing that should be able to speak FastCGI to this pool.
        '';
      };

      listenGroup = lib.mkOption {
        type = lib.types.str;
        default = "caddy";
        description = "Group of the php-fpm listening socket.";
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.oneOf [
            lib.types.str
            lib.types.int
            lib.types.bool
          ]
        );
        default = {
          pm = "dynamic";
          "pm.max_children" = 32;
          "pm.start_servers" = 2;
          "pm.min_spare_servers" = 2;
          "pm.max_spare_servers" = 4;
        };
        description = "Process-manager tuning for the pool.";
      };
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.nullOr (
          lib.types.oneOf [
            lib.types.str
            lib.types.int
            lib.types.bool
          ]
        )
      );
      default = { };
      example = lib.literalExpression ''
        {
          LEAN_ALLOW_TELEMETRY = false;
          LEAN_DEFAULT_TIMEZONE = "Europe/Athens";
        }
      '';
      description = ''
        Additional LEAN_* variables, merged over the ones derived from the
        options above. See upstream's config/sample.env for the full surface.

        Freeform, so a misspelled key is accepted silently and does nothing.
        Do not put secrets here -- they would land in the world-readable store.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to an EnvironmentFile holding secrets, e.g. LEAN_SESSION_PASSWORD
        (which salts sessions and must be stable across restarts) and
        LEAN_DB_PASSWORD if peer authentication is not being used.

        Read by systemd, not by Nix, so the contents stay out of the store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.database.type == "pgsql" -> cfg.database.user == cfg.user;
        message = ''
          services.leantime: peer authentication requires database.user to equal
          the system user, since the OS identity is the credential. Set
          database.user = "${cfg.user}" or switch to password authentication.
        '';
      }
    ];

    users.users.${cfg.user} = lib.mkIf (cfg.user == "leantime") {
      isSystemUser = true;
      inherit (cfg) group;
      home = cfg.dataDir;
    };

    users.groups.${cfg.group} = lib.mkIf (cfg.group == "leantime") { };

    # Mirrors the four symlink targets baked into the package. Laravel creates
    # neither the framework/ subtree nor bootstrap-cache on demand -- a missing
    # one surfaces as a 500 with the reason buried in storage/logs.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir}                            0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/storage                    0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/storage/framework          0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/storage/framework/cache    0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/storage/framework/sessions 0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/storage/framework/views    0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/storage/logs               0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/bootstrap-cache            0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/userfiles                  0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/public-userfiles           0750 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/backupdb                   0750 ${cfg.user} ${cfg.group} - -"
    ];

    services.phpfpm.pools.leantime = {
      inherit phpPackage;
      inherit (cfg) user group;

      phpEnv = lib.mapAttrs (_: toEnvValue) settings;

      settings = {
        "listen.owner" = cfg.pool.listenOwner;
        "listen.group" = cfg.pool.listenGroup;
        "listen.mode" = "0660";

        # Without this php-fpm scrubs the parent environment before spawning
        # workers, and the secrets delivered by EnvironmentFile below never
        # reach PHP -- silently, as missing config rather than as an error.
        "clear_env" = false;
      }
      // cfg.pool.settings;
    };

    systemd.services.phpfpm-leantime = {
      serviceConfig = lib.mkIf (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };
    }
    // lib.optionalAttrs (cfg.database.type == "pgsql") {
      after = [ "postgresql.target" ];
      requires = [ "postgresql.target" ];
    };

    # No webserver virtual host is declared here, deliberately.
    #
    # Leantime is served as static files plus FastCGI rather than an HTTP
    # upstream, so it needs `root` + `file_server` + `php_fastcgi` rather than
    # the `reverse_proxy` most services get. That block belongs in the host's
    # seta.<svc>.proxy.config, where the exposure guard wraps it -- a vhost
    # declared from inside this module would bypass that guard entirely, which
    # is the one failure mode an access control must not have.
    #
    # The document root is:
    #   ${cfg.package}/share/leantime/public
    # and the pool socket is:
    #   /run/phpfpm/leantime.sock
  };
}
