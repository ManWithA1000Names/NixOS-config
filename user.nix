{  pkgs, username, ... }: {
  users.users.${username} = {
    isNormalUser = true;
    description = "The human user";
    hashedPassword =
      "$6$Vo4Ra4ruT0so3jWq$OY2Wn/Vx8.xs1zo7qcu3xJ9aQ/fZf4r.qzwOtiTjSNcH9X0HpMffhBQRVvlE9y.La7Fhak/erHpFTUc.MVKrD1";

    extraGroups =
      [ "networkmanager" "wheel" "kvm" "input" "libvirtd" "docker" ];

    shell = pkgs.fish;

    packages = with pkgs; [ fd bat eza aria file peco ripgrep starship zoxide ];
  };
}
