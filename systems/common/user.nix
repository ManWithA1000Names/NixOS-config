{
  pkgs,
  USERNAME,
  MEDIA_GROUP,
  ...
}:
{
  users.users.${USERNAME} = {
    description = "The human user.";
    isNormalUser = true;

    uid = 1000;

    # Read/write access to the shared media library at /mnt/ex-ssd/media.
    extraGroups = [
      MEDIA_GROUP
      "wheel"
      "kvm"
      "input"
    ];

    shell = pkgs.fish;
  };

  # Shared group that owns everything under MEDIA_ROOT. Every service that
  # touches media files runs with this as its primary group, and the human
  # user is a member too.
  users.groups.${MEDIA_GROUP} = {
    gid = 985;
  };
}
