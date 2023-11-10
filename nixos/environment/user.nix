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
      mpv
      vlc
      fnm
      peco
      htop
      brave
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
      hyprpicker
      popcorntime
    ];
  };
}
