{ pkgs, ... }: {
  programs.hyprland = {
    enable = true;
    xwayland = { enable = true; };
    enableNvidiaPatches = true;
  };

  xdg.portal = {
    enable = true;
    wlr.enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };
}
