_: {
  imports = [
    ./monitoring/netdata.nix
    ./monitoring/notify.nix
    ./monitoring/checks.nix
  ];

  # ---------------------------------------------------------------------------
  # Journald
  #
  # The journal is the log store, not a staging area. Nothing copies it
  # anywhere and nothing writes a second copy to this disk.
  #
  # It is also the *only* store: Netdata's systemd-journal plugin is disabled
  # (monitoring/netdata.nix explains why), so there is no web view of these
  # files. They are read with journalctl over SSH.
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
