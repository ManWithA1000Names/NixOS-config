_: {
  services = {
    printing.enable = true;

    hypridle.enable = true;

    avahi = {
      enable = true;
      nssmdns4 = true;
    };

    openssh = {
      enable = true;
      settings.PermitRootLogin = "no";
    };
  };
}
