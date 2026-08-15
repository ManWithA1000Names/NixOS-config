rec {
  NAME = "Paperless";
  SUB-DOMAIN = "paperless";
  PORT = 28981;
  GROUP = "Apps";
  DESCRIPTION = "Document manager";
  ICON = "paperless-ngx.png";

  SERVICE = "paperless";

  config = { toDomain, ... }: {
    enable = true;

    port = PORT;
    domain = toDomain SUB-DOMAIN;
  };
}
