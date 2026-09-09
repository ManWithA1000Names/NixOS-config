let
  operating = builtins.readFile ../public-keys/operating.pub;
  users = [ operating ];

  o700 = builtins.readFile ../public-keys/ssh_o700_host_ed25519_key.pub;
  systems = [ o700 ];
in
{
  "cloudflare-dns-api.age".publicKeys = systems ++ users;
  "alerting.age".publicKeys = systems ++ users;
  "opencloud-env.age".publicKeys = systems ++ users;
  "n8n-encryption-key.age".publicKeys = systems ++ users;

  # The restic repository password and the Backblaze B2 application key.
  #
  # `users` -- the `operating` key held on big-boss -- is not optional padding
  # here, it is the entire recovery path. Both of these are needed in exactly
  # the disaster where o700's root disk is gone, and the o700 host key that
  # would otherwise decrypt them lives on that disk. Keyed to both identities,
  # the backups stay readable from big-boss with o700 absent.
  "restic-password.age".publicKeys = systems ++ users;
  "restic-b2.age".publicKeys = systems ++ users;

  "user-password.age".publicKeys = [ o700 ] ++ users;
}
