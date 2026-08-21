{
  lib,
  PORTS,
  ...
}:
let
  # Services whose logs do NOT reach the journal and must be tailed from disk.
  #
  # Empty today: everything on this host logs to stdout/stderr, so the journald
  # source below already captures it. Entries get added here as they are
  # discovered -- Jellyfin, for instance, writes its own rotating files under
  # /var/lib/jellyfin/log in addition to whatever it sends to the journal.
  #
  #   { name = "jellyfin"; paths = [ "/var/lib/jellyfin/log/*.log" ]; }
  #
  # `name` becomes the `unit` stream field, so file-sourced logs share a
  # namespace with journal-sourced ones and one query covers both. Keep it
  # equal to the systemd unit name where a unit exists, so that a service which
  # logs to both places does not split across two stream identities.
  logFiles = [ ];

  fileSources = builtins.listToAttrs (
    map (f: {
      name = "file_${f.name}";
      value = {
        type = "file";
        include = f.paths;

        # logrotate renames the live file and creates a fresh one in its place.
        # Vector follows the rename by inode, so the rotated copy must not also
        # match as a newly-appeared file -- that re-ingests its entire contents
        # on every rotation, duplicating a day of logs each time.
        exclude = [
          "**/*.gz"
          "**/*.[0-9]"
          "**/*.log.*"
        ];

        # Only matters the first time a path is seen; thereafter Vector resumes
        # from the checkpoint in data_dir. "beginning" means adding a service
        # here backfills whatever the file still holds instead of silently
        # starting from now.
        read_from = "beginning";
      };
    }) logFiles
  );

  fileTransforms = builtins.listToAttrs (
    map (f: {
      name = "norm_file_${f.name}";
      value = {
        type = "remap";
        inputs = [ "file_${f.name}" ];
        source = ''
          .unit = "${f.name}"
          .source_kind = "file"
        '';
      };
    }) logFiles
  );

  sinkInputs = [ "norm_journal" ] ++ map (f: "norm_file_${f.name}") logFiles;
in
{
  services.vector = {
    enable = true;

    # Deliberately false. The capability set below already grants read access to
    # the journal files, so membership of the systemd-journal group would be a
    # second, redundant mechanism for the same thing.
    journaldAccess = false;

    settings = {
      # Required for the disk buffer on the sink. Matches StateDirectory=vector
      # in the nixpkgs module, which is the only writable path this unit has.
      data_dir = "/var/lib/vector";

      sources = {
        journal = {
          type = "journald";
          # false, so a Vector outage spanning a reboot still picks up the
          # previous boot's entries rather than skipping to the current one.
          current_boot_only = false;
        };

        # Vector's own throughput, error and buffer counters. Without these,
        # "is the pipeline healthy" can only be answered by the absence of
        # logs, which is indistinguishable from a quiet system.
        internal = {
          type = "internal_metrics";
        };
      }
      // fileSources;

      transforms = {
        norm_journal = {
          type = "remap";
          # Vector's journald source renames _HOSTNAME to `host` and MESSAGE to
          # `message`, and passes the remaining journal fields through under
          # their original names. Confirm the exact set once on the host:
          #   curl -s 127.0.0.1:9428/select/logsql/query \
          #     --data-urlencode 'query=*' --data-urlencode 'limit=1'
          #
          # VRL's `||` coalesces null, so this walks a fallback chain. If
          # _SYSTEMD_UNIT never arrives under that name the field lands as
          # "unknown" and everything collapses into one stream -- worse to
          # query, but not a cardinality problem, so the failure is safe.
          inputs = [ "journal" ];
          source = ''
            .unit = to_string(._SYSTEMD_UNIT || .SYSLOG_IDENTIFIER || "unknown") ?? "unknown"
            .source_kind = "journal"
          '';
        };
      }
      // fileTransforms;

      sinks = {
        victorialogs = {
          # VictoriaLogs implements the Elasticsearch _bulk protocol, which is
          # the only ingestion path both it and Vector speak. Note this is NOT
          # the /insert/journald endpoint systemd-journal-upload used, which is
          # why the -journald.streamFields and -journald.ignoreFields flags
          # were dropped from monitoring.nix: they apply only to that endpoint
          # and became inert config the moment shipping moved here.
          type = "elasticsearch";
          inputs = sinkInputs;
          endpoints = [
            "http://127.0.0.1:${toString PORTS.VICTORIA_LOGS}/insert/elasticsearch"
          ];
          mode = "bulk";

          # Pinned rather than negotiated. Version detection asks for an
          # Elasticsearch root endpoint that VictoriaLogs does not implement,
          # which fails the sink at startup.
          api_version = "v8";
          compression = "gzip";

          # Same reason: the Elasticsearch healthcheck probes a path
          # VictoriaLogs has no handler for, so it reports permanently
          # unhealthy on an otherwise working sink.
          healthcheck.enabled = false;

          query = {
            _msg_field = "message";
            _time_field = "timestamp";
            # Replaces -journald.streamFields. Every distinct combination here
            # is a separate stream with its own overhead, so it must stay
            # bounded by the number of units -- never anything request-derived
            # or PID-derived.
            _stream_fields = "host,unit";
          };

          buffer = {
            # This is what lets journald's retention drop to 500M: the buffer,
            # not the journal, is now what absorbs a VictoriaLogs restart, and
            # unlike the journal it also covers the file sources.
            type = "disk";
            # Vector rejects a disk buffer below 268435488 bytes.
            max_size = 1073741824;
            # Apply backpressure rather than discarding. Vector reads the
            # journal at its own pace, so blocking parks the reader; it does
            # not stall the services doing the logging.
            when_full = "block";
          };
        };

        prometheus = {
          type = "prometheus_exporter";
          inputs = [ "internal" ];
          address = "127.0.0.1:${toString PORTS.VECTOR}";
        };
      };
    };
  };

  # +-----------------------------------------------------------------+
  # | Additional configurations that are required for these services. |
  # +-----------------------------------------------------------------+

  systemd.services.vector = {
    # Ordering only. If VictoriaLogs is down Vector must still start and buffer
    # to disk; a hard dependency would mean a failed log store also costs you
    # the record of why it failed.
    after = [ "victorialogs.service" ];
    wants = [ "victorialogs.service" ];

    serviceConfig = {
      # CAP_DAC_READ_SEARCH bypasses file-read and directory-traverse
      # permission checks and nothing else: read any file anywhere, write
      # nothing. That is exactly the authority a log shipper needs to tail
      # /var/lib/<service>/log directories owned by their respective service
      # users, and it is strictly narrower than running as root -- which is the
      # obvious alternative and a much worse blast radius for a process whose
      # whole job is parsing attacker-controlled strings.
      #
      # mkForce because the nixpkgs module sets CAP_NET_BIND_SERVICE here; no
      # listener in this config binds below 1024, so it is not needed.
      AmbientCapabilities = lib.mkForce [ "CAP_DAC_READ_SEARCH" ];
      CapabilityBoundingSet = lib.mkForce [ "CAP_DAC_READ_SEARCH" ];

      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
    };
  };
}
