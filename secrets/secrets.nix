let
  operating = builtins.readFile ../public-keys/operating.pub;
  users = [ operating ];

  o700 = builtins.readFile ../public-keys/ssh_o700_host_ed25519_key.pub;
  systems = [ o700 ];
in
{
  "cloudflare-dns-api.age".publicKeys = systems ++ users;
  "alerting.age".publicKeys = systems ++ users;
}
