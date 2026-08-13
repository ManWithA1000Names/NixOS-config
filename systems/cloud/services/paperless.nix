rec {
  NAME = "Paperless";
  SUB-DOMAIN = "paperless";
  PORT = 28981;

  SERVICE = "paperless";

  config = { toDomain, ... }: {
    enable = true;

    port = PORT;
    domain = toDomain SUB-DOMAIN;
  };
}
