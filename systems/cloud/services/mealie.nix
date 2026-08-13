rec {
  NAME = "Mealie";
  SUB-DOMAIN = "mealie";
  PORT = 8002;

  SERVICE = "mealie";

  config = { toDomain, ... }: {
    enable = true;

    port = PORT;
    settings.BASE_URL = toDomain SUB-DOMAIN;
  };
}
