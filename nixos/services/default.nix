_: {
  services = {
    printing.enable = true;

    hypridle.enable = true;

    gnome.gnome-keyring.enable = true;

    avahi = {
      enable = true;
      nssmdns4 = true;
    };

    openssh = {
      enable = true;
      settings.PermitRootLogin = "no";
    };

    ollama = {
      enable = true;
      acceleration = "cuda";
      loadModels = [ "gemma3:27b" "deepseek-r1:32b" ];
    };
  };
}
