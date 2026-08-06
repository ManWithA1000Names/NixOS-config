{ pkgs, ... }: {
  services = {

    hypridle.enable = true;

    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    greetd = {
      enable = true;
      settings = rec {
        initial_session = {
          command = "${pkgs.hyprland}/bin/start-hyprland";
          user = "user";
        };
        default_session = initial_session;
      };
    };
  };

  security.pam.services.greetd.enableGnomeKeyring = true;

  programs.hyprland = {
    enable = true;
    xwayland = { enable = true; };
  };

  xdg.portal = {
    enable = true;
    wlr.enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  fonts = {
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
      font-awesome
      source-han-sans
      nerd-fonts.fira-code
    ];
    fontconfig.defaultFonts = {
      serif = [ "Noto Serif" "Source Han Serif" ];
      sansSerif = [ "Noto Sans" "Source Han Sans" ];
    };
  };

  # Make volantes cursors default cursor theme
  environment.extraSetup = ''
    mkdir $out/share/icons/default
    cat << EOF > $out/share/icons/default/index.theme
    [Icon Theme]
    Inherits=volantes_light_cursors
    EOF
  '';
}
