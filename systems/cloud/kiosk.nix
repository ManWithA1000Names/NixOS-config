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
      lightdm = {
        enable = true;
        autoLogin = {
          enable = true;
          user = "user";
        };
      };

      defaultSession = "kodi-kiosk";
      sessionPackages = [ kodiKioskSession ];

      # Run once per X session before the window manager starts.
      sessionCommands = ''
        # Disable the laptop's built-in panel; only the HDMI output should be
        # active. Under NVIDIA PRIME sync the panel is usually "eDP-1-1" (PRIME
        # appends the extra -1). Run `xrandr --query` after first boot to confirm.
        ${pkgs.xorg.xrandr}/bin/xrandr --output eDP-1-1 --off 2>/dev/null || \
        ${pkgs.xorg.xrandr}/bin/xrandr --output eDP-1 --off 2>/dev/null || true

        # Kill X11's own DPMS and screen blanking. Kodi manages idle/blanking
        # itself; X11 DPMS firing mid-movie would blank the screen unexpectedly.
        ${pkgs.xorg.xset}/bin/xset s off
        ${pkgs.xorg.xset}/bin/xset dpms 0 0 0
        ${pkgs.xorg.xset}/bin/xset -dpms
      '';
    };
  };

  environment.systemPackages = with pkgs; [
    chromium
    libcec      # provides cec-client for ad-hoc CEC commands from the shell
    kodiWithAddons
  ];

  # Lay down the Kodi userdata directory and drop the advancedsettings symlink.
  # 'L+' means: create/replace with a managed symlink; NixOS is authoritative.
  systemd.tmpfiles.rules = [
    "d  /home/user/.kodi/userdata                        0755 user users - -"
    "L+ /home/user/.kodi/userdata/advancedsettings.xml   -    user users - ${kodiAdvancedSettings}"
  ];

}
