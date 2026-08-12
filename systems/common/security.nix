{ ... }: {
  # Caddy on 'cloud' issues its own certs for the .local hosts (local_certs),
  # so its root has to be trusted explicitly.
  security.pki.certificateFiles = [ ./caddy-local-root.crt ];

  # Node bundles its own root store and ignores /etc/ssl entirely, so
  # Node-based clients (bitwarden-cli) need to be pointed at the system bundle.
  # The variable is additive, public CAs keep working.
  environment.variables.NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-certificates.crt";
}
