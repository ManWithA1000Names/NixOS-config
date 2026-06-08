_: {
  services = {
    printing.enable = true;

    hypridle.enable = true;

    gnome.gnome-keyring.enable = true;

    blueman.enable = true;

    resolved = {
      enable = true;
      # Make sure avahi and resolved do not
      # publish the same information.
      settings.Resolve.MulticastDNS = "resolve";
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
