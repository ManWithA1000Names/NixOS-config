rec {
  NAME = "Kavita";
  SUB-DOMAIN = "kavita";
  PORT = 28981;

  SERVICE = "kavita";

  config = { toDomain, ... }: {
    enable = true;

    settings.Port = PORT;
    tokenKeyFile = "/var/lib/kavita/secrets/tokenKey";
  };
}
