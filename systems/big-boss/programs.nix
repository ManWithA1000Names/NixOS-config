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
  ];

  programs = {
    mtr.enable = true;

    nix-ld.enable = true;

    hyprlock.enable = true;

    gamemode.enable = true;
  };
}
