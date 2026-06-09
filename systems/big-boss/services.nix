_: {
  services = {
    printing.enable = true;

    gnome.gnome-keyring.enable = true;

    blueman.enable = true;

    resolved = {
      enable = true;
      # Make sure avahi and resolved do not
      # publish the same information.
      settings.Resolve.MulticastDNS = "resolve";
    };
  };
}
