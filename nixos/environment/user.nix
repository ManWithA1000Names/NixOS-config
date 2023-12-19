{ pkgs, ... }: {
  users.users.user = {
    isNormalUser = true;
    description = "The human user";
    extraGroups =
      [ "networkmanager" "wheel" "kvm" "input" "libvirtd" "docker" ];
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
      aria
      peco
      kitty
      zoxide
      pamixer
      ripgrep
      discord
      firefox
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
