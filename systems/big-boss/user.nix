{ pkgs, USERNAME, ... }: {
  nix.settings.trusted-users = [ USERNAME "@wheel" ];

  users.users.${USERNAME} = {
    extraGroups = [ "networkmanager" "docker" ];

    packages = with pkgs; [
      fd
      jq
      bat
      feh
      eza
      mpv
      vlc
      fnm
      grim
      slurp
      aria2
      peco
      kitty
      zoxide
      pamixer
      ripgrep
      discord
      (firefox.override {
        extraPrefs = ''
          defaultPref("media.hardware-video-decoding-vulkan.enabled", true);
          defaultPref("media.hardware-video-decoding-vulkan.direct-export.enabled", true);
        '';
      })
      starship
      playerctl
      alacritty
      hyprpaper
      grimblast
      hyprpicker
      popcorntime
    ];
  };
}
