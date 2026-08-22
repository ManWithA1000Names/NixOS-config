_: {
  imports = [
    ./monitoring/netdata.nix
    ./monitoring/notify.nix
    ./monitoring/checks.nix
  ];

  # ---------------------------------------------------------------------------
  # Journald
  #
  # The journal is now the log store, not a staging area. Nothing copies it
  # anywhere -- Netdata's systemd-journal plugin queries these files in place
  # when the dashboard asks, which is the whole reason the previous shipping
  # pipeline (Vector -> VictoriaLogs) could be deleted rather than replaced.
  #
  # The practical consequence is that these two numbers now set log retention
  # outright. There is no second copy to fall back on.
  # ---------------------------------------------------------------------------

  services.journald.extraConfig = ''
    # At the current rate -- roughly 65 Caddy access-log lines a minute plus
    # everything else -- this is on the order of weeks. It also matters more
    # than the size suggests: fail2ban reads this journal, so entries aging out
    # early costs bans, not just history.
    SystemMaxUse=10G

    # Guarantees the root disk keeps headroom regardless of the cap above,
    # since journald is not the only thing writing to it.
    SystemKeepFree=4G
  '';
}
