{ pkgs, USERNAME, ... }: {
  users.users.${USERNAME} = {
    openssh.authorizedKeys.keys =
      [ (builtins.readFile ../../public-keys/id_ed25519.pub) ];

    packages = with pkgs; [ fd bat eza aria2 file peco ripgrep starship ];
  };
}
