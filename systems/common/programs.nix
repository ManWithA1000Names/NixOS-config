{ pkgs, ... }: {
  # Imported by both hosts, so anything added here lands on the WAN-facing
  # server as well as on the workstation. gcc, gnumake and python3 used to be
  # in this list and are now in systems/big-boss/programs.nix instead: nothing
  # on o700 compiles, because closures are built on big-boss and pushed (see
  # the justfile) and Nix builds use the store's toolchain rather than
  # environment.systemPackages. On the server they were three toolchains handed
  # to anything that gets a shell, for no function at all.
  environment.systemPackages = with pkgs; [
    # bare bone basics
    vim
    curl
    htop
    wget
    just
  ];

  programs = {
    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };

    fish.enable = true;

    git = {
      enable = true;
      lfs.enable = true;
      config = {
        init = {
          defaultBranch = "main";
        };
        alias = {
          hist = ''log --pretty=format:"%Cgreen%h %Creset%cd %Cblue[%cn] %Creset%s%C(yellow)%d%C(reset)" --graph --date=relative --decorate --all'';
          root = "rev-parse --show-toplevel";
          list = "branch";
          p = "push";
          s = "status";
          ch = "checkout";
          a = "!git add $(git root)";
          c = "commit -m";
          ac = "!git a && git c";
        };
        pull = {
          rebase = false;
        };
      };
    };
  };
}
