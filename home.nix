{ username, fishConfigSource, ... }: {

  home = {
    inherit username;
    homeDirectory = "/home/${username}";

    # file."${config.xdg.configHome}/fish".source =
    #   config.lib.file.mkOutOfStoreSymlink fishConfigSource;

    stateVersion = "25.05";
  };

  xdg.configFile.fish = {
    source = fishConfigSource;
    recursive = true;
  };

  programs.home-manager.enable = true;
}
