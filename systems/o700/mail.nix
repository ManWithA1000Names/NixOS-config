{
  PORTS,
  DOMAIN,
  ...
}:
{
  services.mailpit.instances.main = {
    # Relative path: lands in /var/lib/mailpit-main/mailpit.db, survives rebuilds.
    database = "mailpit.db";

    # Loopback only. Application services point their SMTP config here;
    # nothing outside this host should submit mail.
    smtp = "127.0.0.1:${toString PORTS.MAILPIT_SMTP}";

    # Loopback only. Caddy proxies this via the seta entry below.
    listen = "127.0.0.1:${toString PORTS.MAILPIT_HTTP}";

    # Prune oldest messages once this limit is reached. 0 = unlimited.
    max = 500;
  };

  seta.mailpit = {
    proxy = {
      enable = true;
      port = PORTS.MAILPIT_HTTP;
      domain = "mailpit-internal.${DOMAIN}";
      exposure = "NONE";
    };
  };
}
