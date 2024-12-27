{ pkgs, ... }: {
  users.users.user = {
    isNormalUser = true;
    description = "The human user";
    extraGroups =
      [ "networkmanager" "wheel" "kvm" "input" "libvirtd" "docker" ];
    shell = pkgs.fish;
    packages = with pkgs; [
      fd
      bat
      feh
      eza
      mpv
      grim
      wofi
      aria
      file
      peco
      slurp
      kitty
      pamixer
      ripgrep
      firefox
      starship
      playerctl
      hyprpaper
      grimblast
      hyprpicker
    ];
  };
}
