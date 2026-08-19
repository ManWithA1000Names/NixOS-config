{ pkgs, MEDIA_GROUP, USERNAME, ... }: {
  users.users.${USERNAME} = {
    description = "The human user.";
    isNormalUser = true;

    # The UID is pinned so it stays consistent across the systems that use NFS.
    uid = 1000;

    # Read/write access to the shared media library at /mnt/ex-ssd/media.
    extraGroups = [ MEDIA_GROUP "wheel" "kvm" "input" "docker" ];

    shell = pkgs.fish;
  };

  # Shared group that owns everything under MEDIA_ROOT. Every service that
  # touches media files runs with this as its primary group (set above),
  # and the human user is a member too (see o700/user.nix).
  #
  # The GID is pinned to a fixed, known value because the NFS access requires stable IDs.
  users.groups.${MEDIA_GROUP} = { gid = 985; };
}
