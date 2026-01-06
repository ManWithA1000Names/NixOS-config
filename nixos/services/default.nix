_: {
  services = {
    printing.enable = true;

    hypridle.enable = true;

    gnome.gnome-keyring.enable = true;

    blueman.enable = true;

    resolved.enable = true;

    openssh = {
      enable = true;
      settings.PermitRootLogin = "no";
    };

    ollama = {
      enable = true;
      acceleration = "cuda";
      loadModels = [ "gemma3:27b" "deepseek-r1:32b" ];
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

    jellyfin = {
      enable = true;
      dataDir = "/mnt/ex-ssd/jellyfin/";
    };
  };
}
