{ pkgs, ... }:
let
  kodiWithAddons = pkgs.kodi.withPackages (ps: with ps; [
    # Jellyfin library integration: connects to the local Jellyfin server
    # (localhost:8096) and syncs the media library into Kodi's UI.
    jellyfin
    # Required by the Jellyfin addon for adaptive-bitrate streams.
    inputstream-adaptive
    inputstream-ffmpegdirect
  ]);

  # Wrapper that auto-restarts Kodi if it ever exits (crash, update, etc.).
  # Lives in the Nix store so nothing is left untracked.
  kodiStartScript = pkgs.writeShellScript "kodi-kiosk-start" ''
    # At boot the NVIDIA X screen comes up with MetaModes "NULL" (640x480):
    # the TV hangs off the Intel provider and PRIME only wires it in a moment
    # later. Kodi launched inside that window gets VDP_STATUS_NO_IMPLEMENTATION
    # from vdp_device_create_x11 and then runs the whole session on CPU decode.
    # Wait for an output to have a real mode before the first launch.
    tries=0
    until ${pkgs.xrandr}/bin/xrandr | ${pkgs.gnugrep}/bin/grep -qE ' connected .*[0-9]+x[0-9]+\+'; do
      tries=$((tries + 1))
      if [ $tries -ge 60 ]; then
        echo "kodi-kiosk: timed out waiting for a connected display -- VDPAU may be unavailable" >&2
        break
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done

    # The EDID advertises 4096x2160 -- DCI cinema 4K, 17:9 -- as its widest
    # mode, so X selects it, but the panel is 16:9 (EDID reports 1600x900mm).
    # The TV then squeezes the image horizontally: everything looks narrow with
    # nothing actually cropped. 3840x2160 is the matching 16:9 UHD mode, and is
    # what consumer content is mastered for. Kodi has
    # videoscreen.screenmode=DESKTOP, so it inherits whatever is set here.
    tv=$(${pkgs.xrandr}/bin/xrandr \
      | ${pkgs.gawk}/bin/awk '/ connected [0-9]/ && $1 !~ /^eDP/ {print $1; exit}')
    if [ -n "$tv" ]; then
      ${pkgs.xrandr}/bin/xrandr --output "$tv" --mode 3840x2160 --rate 30 || true
      # xrandr mode changes reset PRIME Synchronization to 0, which causes tearing
      # because the Intel scan-out races ahead of the NVIDIA render. Re-enable it.
      ${pkgs.xrandr}/bin/xrandr --output "$tv" --set "PRIME Synchronization" 1 || true
    fi

    while true; do
      ${kodiWithAddons}/bin/kodi-standalone
    done
  '';

  # LightDM session descriptor picked up via sessionPackages.
  # providedSessions is required by the NixOS sessionPackages type check.
  kodiKioskSession = pkgs.runCommand "kodi-kiosk-session" {
    passthru.providedSessions = [ "kodi-kiosk" ];
  } ''
    mkdir -p $out/share/xsessions
    cat > $out/share/xsessions/kodi-kiosk.desktop <<'EOF'
    [Desktop Entry]
    Name=kodi-kiosk
    Exec=${kodiStartScript}
    Type=Application
    EOF
  '';

  # Read-only by Kodi (never written to), so a Nix-store symlink is safe.
  # Breaks every power-coupling between the TV and this machine while keeping
  # full CEC remote-control support intact:
  #   - TV standby does NOT stop Kodi or any server process.
  #   - Kodi exit / system shutdown does NOT power off the TV.
  #   - Screensaver onset does NOT put the TV into standby.
  kodiAdvancedSettings = pkgs.writeText "kodi-advancedsettings.xml" ''
    <advancedsettings version="1.0">
      <cec>
        <standby_devices_on_shutdown>false</standby_devices_on_shutdown>
        <power_off_on_standby>false</power_off_on_standby>
        <standby_on_screensaver>false</standby_on_screensaver>
        <wake_devices_on_start>false</wake_devices_on_start>
      </cec>
    </advancedsettings>
  '';
in {

  services.xserver = {
    enable = true;
    # videoDrivers = [ "nvidia" ] is already declared in hardware-configuration.nix.

    displayManager = {
      lightdm.enable = true;

      # Run once per X session before the window manager starts.
      sessionCommands = ''
        # Disable the laptop's built-in panel; only the HDMI output should be
        # active. Under NVIDIA PRIME sync the panel is usually "eDP-1-1" (PRIME
        # appends the extra -1).
        ${pkgs.xrandr}/bin/xrandr --output eDP-1-1 --off 2>/dev/null || \
        ${pkgs.xrandr}/bin/xrandr --output eDP-1 --off 2>/dev/null || true

        # Kill X11's own DPMS and screen blanking. Kodi manages idle/blanking
        # itself; X11 DPMS firing mid-movie would blank the screen unexpectedly.
        ${pkgs.xset}/bin/xset s off
        ${pkgs.xset}/bin/xset dpms 0 0 0
        ${pkgs.xset}/bin/xset -dpms
      '';
    };
  };

  services.displayManager = {
    autoLogin = {
      enable = true;
      user = "user";
    };

    defaultSession = "kodi-kiosk";
    sessionPackages = [ kodiKioskSession ];
  };

  environment.systemPackages = with pkgs; [
    libcec      # provides cec-client for ad-hoc CEC commands from the shell
    kodiWithAddons
  ];

  # Lay down the Kodi userdata directory and drop the advancedsettings symlink.
  # 'L+' means: create/replace with a managed symlink; NixOS is authoritative.
  systemd.tmpfiles.rules = [
    "d  /home/user/.kodi                                 0755 user users - -"
    "d  /home/user/.kodi/temp                            0755 user users - -"
    "d  /home/user/.kodi/userdata                        0755 user users - -"
    "L+ /home/user/.kodi/userdata/advancedsettings.xml   -    user users - ${kodiAdvancedSettings}"
  ];

  # Two separate defects, same fix point. WirePlumber restores a saved 40%
  # level on the HDMI sink, which is why Kodi needs the TV at 60 to match what
  # every other input does at 10-15. And the analog headphone jack is the
  # system default sink, so anything that does not pin a device explicitly --
  # mpv, for instance -- plays into the laptop's headphone socket rather than
  # the TV. Kodi is unaffected by that second one only because it names the
  # HDMI device outright in its own settings.
  #
  # pactl is used rather than wpctl because it addresses sinks by name; wpctl
  # needs the numeric object id, which is not stable across boots.
  systemd.user.services.hdmi-audio-defaults = {
    description = "Make HDMI the default sink and pin it to full volume";
    wantedBy = [ "default.target" ];
    after = [ "pipewire-pulse.service" "wireplumber.service" ];
    path = [ pkgs.pulseaudio pkgs.coreutils pkgs.gnugrep ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Wait for any HDMI sink to appear. Matching on "hdmi" in the sink
      # name is stable across PCI re-enumeration and BIOS updates unlike
      # a hardcoded alsa_output.pci-<addr> name.
      tries=0
      until pactl list sinks short | grep -qi hdmi; do
        tries=$((tries + 1))
        [ $tries -ge 30 ] && exit 0
        sleep 1
      done

      sink=$(pactl list sinks short | awk '/[Hh][Dd][Mm][Ii]/ {print $2; exit}')
      pactl set-default-sink "$sink"
      pactl set-sink-volume "$sink" 100%
    '';
  };

}
