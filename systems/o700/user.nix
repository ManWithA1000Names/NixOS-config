{
  pkgs,
  MEDIA_GROUP,
  USERNAME,
  ...
}:
{
  users.users.${USERNAME} = {
    description = "The human user.";
    isNormalUser = true;

    extraGroups = [
      MEDIA_GROUP
      "wheel"
      "kvm"
      "input"
    ];

    openssh.authorizedKeys.keys = [ (builtins.readFile ../../public-keys/id_ed25519.pub) ];

    packages = with pkgs; [
      fd
      bat
      eza
      aria2
      file
      peco
      ripgrep
      starship
    ];

    shell = pkgs.fish;
  };

  users.groups.${MEDIA_GROUP} = {
    gid = 985;
  };
}
