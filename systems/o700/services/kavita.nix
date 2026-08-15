rec {
  NAME = "Kavita";
  SUB-DOMAIN = "kavita";
  PORT = 5000;
  GROUP = "Media";
  DESCRIPTION = "Manga & comics";
  ICON = "kavita.png";

  SERVICE = "kavita";

  config = { toDomain, ... }: {
    enable = true;

    settings.Port = PORT;
    tokenKeyFile = "/var/lib/kavita/secrets/tokenkey";
  };
}
