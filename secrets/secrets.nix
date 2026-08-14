let
  operating = builtins.readFile ../public-keys/operating.pub;
  users = [ operating ];

  cloud = builtins.readFile ../public-keys/ssh_cloud_host_ed25519_key.pub;
  systems = [ cloud ];
in {
  "cloudflare-dns-api.age".publicKeys = systems ++ users;
}
