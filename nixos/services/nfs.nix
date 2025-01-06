_: {
  services.nfs.server.enable = true;

  services.nfs.server.exports = ''
    /export 192.168.1.0/24(rw,sync,no_subtree_check)
  '';

}
