{ pkgs, ... }: {
  users.users.user = {
    isNormalUser = true;
    description = "The human user";

    extraGroups =
      [ "networkmanager" "wheel" "kvm" "input" "libvirtd" "docker" ];

    shell = pkgs.fish;

    packages = with pkgs; [ fd bat eza aria file peco ripgrep starship ];
  };
}
