_: {
  services = {
    printing.enable = true;

    hypridle.enable = true;

    gnome.gnome-keyring.enable = true;

    blueman.enable = true;

    resolved = {
      enable = true;
      # This is handled by avahi.
      # Leaving this on would cause race conditions.
      settings.Resolve.MulticastDNS = "no";
    };

    openssh = {
      enable = true;
      settings.PermitRootLogin = "no";
    };

    avahi = {
      enable = true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
        workstation = true;
        userServices = true;
      };
    };
  };
}
