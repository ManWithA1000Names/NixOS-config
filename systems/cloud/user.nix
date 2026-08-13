{ pkgs, MEDIA_GROUP, ... }: {
  users.users.user = {
    isNormalUser = true;
    # Pinned so the NFS export (hardware-configuration.nix) can squash every
    # client onto this UID. The first normal user is 1000 already, so this is
    # normally a no-op; it just makes the value explicit and referenceable.
    uid = 1000;
    description = "The human user";

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKvGywW2M93I8qbcmQanE9GAEggfUGiwLCP3fAPip6mV user@big-boss"
    ];

    extraGroups = [
      "networkmanager"
      "wheel"
      "kvm"
      "input"
      "libvirtd"
      "docker"
      # Read/write access to the shared media library at /mnt/ex-ssd/media.
      MEDIA_GROUP
    ];

    shell = pkgs.fish;

    packages = with pkgs; [ fd bat eza aria2 file peco ripgrep starship ];
  };
}
