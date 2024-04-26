{ pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    # bare bone basics
    gcc
    vim
    curl
    htop
    wget
    gnumake
    python3
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

    # themes
    volantes-cursors
  ];

  programs = {
    mtr.enable = true;
    gamemode.enable = true;
    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };
    fish.enable = true;
    git = {
      enable = true;
      lfs.enable = true;
      config = {
        init = { defaultBranch = "main"; };
        alias = {
          hist = ''
            log --pretty=format:"%Cgreen%h %Creset%cd %Cblue[%cn] %Creset%s%C(yellow)%d%C(reset)" --graph --date=relative --decorate --all'';
          root = "rev-parse --show-toplevel";
          list = "branch";
          p = "push";
          s = "status";
          ch = "checkout";
          a = "!git add $(git root)";
          c = "commit -m";
          ac = "!git a && git c";
        };
        pull = { rebase = false; };
      };
    };
  };
}
