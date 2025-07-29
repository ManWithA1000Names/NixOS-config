{ pkgs, ... }: {
  users.users.user = {
    isNormalUser = true;
    description = "The human user";

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKvGywW2M93I8qbcmQanE9GAEggfUGiwLCP3fAPip6mV user@big-boss"
    ];

    extraGroups =
      [ "networkmanager" "wheel" "kvm" "input" "libvirtd" "docker" ];

    shell = pkgs.fish;

    packages = with pkgs; [ fd bat eza aria file peco ripgrep starship ];
  };
}
