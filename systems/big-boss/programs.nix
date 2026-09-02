{ pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    # bare bone basics
    xdg-utils

    # wayland specific
    mako
    wl-clipboard
    egl-wayland
    waybar

    # notfication support
    libnotify
    # to be able to change sound
    pulseaudio

    # launcher
    vicinae

    # themes
    volantes-cursors

    # Firefox PWA's
    firefoxpwa
  ];

  programs = {
    mtr.enable = true;

    nix-ld.enable = true;

    hyprlock.enable = true;

    gamemode.enable = true;

    firefox = {
      enable = true;

      package = pkgs.firefox.override {
        extraPrefs = ''
          defaultPref("media.hardware-video-decoding-vulkan.enabled", true);
          defaultPref("media.hardware-video-decoding-vulkan.direct-export.enabled", true);
        '';
      };

      nativeMessagingHosts.packages = [ pkgs.firefoxpwa ];
    };
  };
}
