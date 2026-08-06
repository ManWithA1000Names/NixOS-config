{ pkgs, ... }:
let username = "user";
in {
  nix.settings.trusted-users = [ username "@wheel" ];

  users.users.${username} = {
    isNormalUser = true;
    description = "The human user";

    extraGroups =
      [ "networkmanager" "wheel" "kvm" "input" "docker" ];

    shell = pkgs.fish;

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
