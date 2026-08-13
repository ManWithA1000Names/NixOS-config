{ MEDIA_GROUP, ... }:
let
  # Shared media storage for the Arr stack, qBittorrent and Jellyfin.
  # Downloads and the final library live under a single root on the same
  # filesystem so Sonarr/Radarr can import via instant hardlinks + atomic
  # moves (no copy, no extra disk usage, seeding keeps working).
  MEDIA_ROOT = "/mnt/ex-ssd/media";
in {

  # Shared group that owns everything under MEDIA_ROOT. Every service that
  # touches media files runs with this as its primary group (set above),
  # and the human user is a member too (see cloud/user.nix).
  #
  # The GID is pinned to a fixed, known value because the NFS export squashes
  # every client onto this group (see hardware-configuration.nix). A stable
  # GID keeps that mapping valid across rebuilds and machines.
  users.groups.${MEDIA_GROUP} = { gid = 985; };

  # Jellyfin only needs to *read* the library, so it joins "media" as a
  # supplementary group rather than changing its primary group.
  users.users.jellyfin.extraGroups = [ MEDIA_GROUP ];

  # Media directory tree. The setgid bit (leading 2 in 2775) makes new
  # subdirectories inherit the "media" group automatically.
  #
  # Note: the parent mount-point /mnt/ex-ssd must be root-owned for these
  # rules to apply -- systemd-tmpfiles refuses an "unsafe path transition"
  # from an unprivileged-user-owned directory into a root-owned one. That
  # ownership is asserted next to the mount in hardware-configuration.nix.
  systemd.tmpfiles.rules = [
    "d ${MEDIA_ROOT}                     2775 root        ${MEDIA_GROUP} - -"
    "d ${MEDIA_ROOT}/torrents            2775 qbittorrent ${MEDIA_GROUP} - -"
    "d ${MEDIA_ROOT}/torrents/incomplete 2775 qbittorrent ${MEDIA_GROUP} - -"
    "d ${MEDIA_ROOT}/torrents/tv         2775 qbittorrent ${MEDIA_GROUP} - -"
    "d ${MEDIA_ROOT}/torrents/movies     2775 qbittorrent ${MEDIA_GROUP} - -"
    "d ${MEDIA_ROOT}/library             2775 root        ${MEDIA_GROUP} - -"
    "d ${MEDIA_ROOT}/library/tv          2775 root        ${MEDIA_GROUP} - -"
    "d ${MEDIA_ROOT}/library/movies      2775 root        ${MEDIA_GROUP} - -"
  ];
}
