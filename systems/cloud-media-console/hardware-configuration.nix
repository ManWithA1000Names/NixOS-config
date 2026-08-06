{ config, lib, pkgs, ... }: {

  nixpkgs.config.problems.handlers.nvidia-x11.broken = "ignore";
  nixpkgs.config.problems.handlers.nvidia-kernel-modules.broken = "ignore";

  boot = {
    initrd.kernelModules =
      [ "nvidia" "nvidia_modeset" "nvidia_drm" ];

    kernelParams = [
      "consoleblank=30"
      # Required for Plymouth to take over the framebuffer early enough to
      # hide the kernel log on the TV. nvidia_drm.modeset=1 is already implied
      # by hardware.nvidia.modesetting.enable = true but listed explicitly here
      # so the intent is obvious.
      "nvidia_drm.modeset=1"
      "quiet"
      "splash"
    ];

    plymouth.enable = true;
  };

  hardware = {
    graphics = { enable = true; };

    nvidia = {
      # nvidia open source kernel module, for 20 series and up only.
      open = false;

      nvidiaSettings = true;
      modesetting.enable = true;

      # The 390.x legacy driver ships libglx.so.390.157 with no libglx.so
      # symlink. X.Org searches for "glx" by canonical filename and skips
      # NVIDIA's extensions dir, loading X.Org's own libglx.so instead.
      # NVIDIA then refuses to initialize GLX and Kodi falls back to swrast.
      # Fix: patch the .bin output to add the missing symlink so the
      # name-based search finds NVIDIA's GLX first.
      package =
        let
          base = config.boot.kernelPackages.nvidiaPackages.legacy_390;
          patchedBin = pkgs.symlinkJoin {
            name = "nvidia-x11-390-with-glx-symlink";
            paths = [
              (pkgs.runCommand "nvidia-glx-symlink" { } ''
                mkdir -p $out/lib/xorg/modules/extensions
                ln -s ${base.bin}/lib/xorg/modules/extensions/libglx.so.390.157 \
                  $out/lib/xorg/modules/extensions/libglx.so
              '')
              base.bin
            ];
          };
        in
        base // { bin = patchedBin; };

      prime = {
        sync.enable = true;
        intelBusId = "PCI:0:2:0";
        nvidiaBusId = "PCI:1:0:0";
      };
    };
  };

  services.xserver.videoDrivers = [ "nvidia" ];
}
