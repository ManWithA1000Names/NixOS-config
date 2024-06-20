_: {
  services = {
    printing.enable = true;

    resolved.enable = true;

    hypridle.enable = true;

    avahi = {
      enable = true;
      nssmdns = true;
    };

    openssh = {
      enable = true;
      settings.PermitRootLogin = "no";
    };
  };
}
