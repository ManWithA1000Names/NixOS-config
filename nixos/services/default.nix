{ pkgs, ... }: {
  services = {
    openssh = {
      enable = true;
      settings.PermitRootLogin = "no";
      knownHosts.big-boss.publicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKvGywW2M93I8qbcmQanE9GAEggfUGiwLCP3fAPip6mV user@big-boss";
    };
  };
}
