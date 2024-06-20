{ pkgs, ... }: {
  programs.hyprland = {
    enable = true;
    xwayland = { enable = true; };
    hyprlock.enable = true;
    hypridle.enable = true;
  };

  xdg.portal = {
    enable = true;
    wlr.enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };
}
