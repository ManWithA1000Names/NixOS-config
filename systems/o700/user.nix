{ pkgs, MEDIA_GROUP, ... }: {
  users.users.user = {
    isNormalUser = true;
    # Pinned so the NFS export (hardware-configuration.nix) can squash every
    # client onto this UID. The first normal user is 1000 already, so this is
    # normally a no-op; it just makes the value explicit and referenceable.
    uid = 1000;
    description = "The human user";

    openssh.authorizedKeys.keys =
      [ (builtins.readFile ../../public-keys/id_ed25519.pub) ];

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
