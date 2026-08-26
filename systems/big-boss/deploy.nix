{
  IP,
  DOMAIN,
  USERNAME,
  ...
}:
{
  # o700 runs with the default `require-sigs = true` and the default
  # `trusted-users` (root only), so it rejects any store path pushed by
  # `user@big-boss` unless the path carries a signature it trusts. Signing
  # locally-built paths here -- rather than making `user` a trusted-user over
  # there -- keeps o700 accepting only what big-boss actually built, instead of
  # anything the big-boss SSH key can hand it.
  nix.settings.secret-key-files = [ "/var/lib/nix/signing/big-boss.key" ];

  systemd.tmpfiles.rules = [ "d /var/lib/nix/signing 0700 root root -" ];

  programs.ssh = {
    knownHosts.o700 = {
      extraHostNames = [
        IP.o700
        DOMAIN
      ];
      publicKeyFile = ../../public-keys/ssh_o700_host_ed25519_key.pub;
    };

    # `HostName` is the literal address rather than a name, so that deploying to
    # o700 does not depend on o700 answering DNS for itself -- it is the LAN's
    # resolver, and it is also the machine being taken down and switched.
    extraConfig = ''
      Host o700
        HostName ${IP.o700}
        User ${USERNAME}
        IdentityFile ~/.ssh/id_ed25519
    '';
  };
}
