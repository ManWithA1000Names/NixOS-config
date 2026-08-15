{
  NAME = "Jellyfin";
  SUB-DOMAIN = "fin";
  PORT = 8096;

  SERVICE = "jellyfin";

  config = { toDomain, ... }: {
    enable = true;

    # The trailing slash is load-bearing -- do not "clean it up".
    #
    # Jellyfin derives every item's GUID from its path, and first strips the
    # dataDir prefix using a plain string comparison, not a path-component
    # one. Without the slash, "/mnt/ex-ssd/jellyfin" is a prefix of
    # "/mnt/ex-ssd/jellyfin-assets/...", so the whole media library hashes to
    # a different set of GUIDs and Jellyfin re-imports every file as a second
    # copy, orphaning watch history and regenerating all trickplay images.
    dataDir = "/mnt/ex-ssd/jellyfin/";
  };
}
