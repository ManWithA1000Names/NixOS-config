{ PORTS, ... }:
{
  networking = {
    hostName = "big-boss";
    networkmanager.enable = true;

    firewall = {
      enable = true;

      # Nothing on this host is meant to be reachable from outside it. It is a
      # workstation: the media share, Gitea, Jellyfin and the rest are all
      # things it connects *out* to on o700. So the correct set of open inbound
      # ports is the empty one, and the exception below is not a service but a
      # discovery protocol that structurally cannot work through conntrack.
      #
      # This matters more than "no listening services, so no firewall needed"
      # suggested: this interface carries a globally routable IPv6 on the same
      # prefix as o700, and the router does not NAT v6. Anything that starts
      # listening on this box -- a dev server bound to 0.0.0.0, a container
      # publishing a port -- is otherwise reachable from the internet the moment
      # it starts, with nothing in between.
      allowedTCPPorts = [ ];

      allowedUDPPorts = [
        # mDNS. resolved runs with MulticastDNS="resolve" and CUPS discovers
        # printers the same way. Both send to 224.0.0.251:5353 and get the
        # answer back as a separate multicast packet rather than as a reply
        # conntrack can associate with the outbound query, so a strict
        # default-deny drops the responses. The failure is a timeout rather
        # than an error, which presents as ".local names are slow" instead of
        # as a firewall problem.
        PORTS.MDNS
      ];
    };

    # Deliberately NOT networking.nftables.enable, unlike o700. Docker is
    # enabled on this host (virtualisation.nix) and installs its own forwarding
    # and NAT rules through the iptables interface; running the nftables
    # backend alongside it puts two tools with different views on the same
    # tables. o700 was able to switch backends precisely because Docker had
    # been removed from it first -- see the comment above its nftables.enable.
  };
}
