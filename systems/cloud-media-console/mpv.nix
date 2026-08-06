{ pkgs, ... }: {

  environment.systemPackages = [ pkgs.mpv ];

  # nixpkgs builds mpv with meson sysconfdir=/etc, so this is the real
  # system-wide config path rather than a store-internal one. It is read by the
  # mpv binary and by any libmpv application that opts into config loading --
  # libmpv itself defaults to config=no, so a client that never sets
  # config=yes/config-dir stays isolated no matter where this file lives.
  environment.etc."mpv/mpv.conf".text = ''
    # --- output ------------------------------------------------------------
    vo=gpu
    gpu-api=opengl
    # GLX rather than EGL: on the 390 legacy driver the zero-copy VDPAU->GL
    # interop (GL_NV_vdpau_interop) is only exposed through GLX. Under EGL mpv
    # silently degrades to vdpau-copy, which round-trips every frame through
    # system memory.
    gpu-context=x11

    # --- decoding ----------------------------------------------------------
    # GK104 has fixed-function decode for H.264 / MPEG2 / VC-1 / MPEG4-ASP and
    # nothing else. HEVC and VP9 have no engine at all and fall back to the CPU
    # on their own, so there is no point listing codec filters here.
    hwdec=vdpau

    # --- scaling -----------------------------------------------------------
    # Deliberately modest. This is a 2014 mobile GPU filling a 4K framebuffer;
    # the ewa_lanczos family used by the high-quality profile drops frames.
    scale=spline36
    dscale=mitchell
    cscale=bilinear
    dither-depth=auto

    # --- HDR -> SDR tone mapping -------------------------------------------
    # The TV is driven by the Haswell iGPU, whose HDMI is 1.4 (which is why the
    # panel's mode list caps 4K at 30Hz). HDR10 needs the HDMI 2.0a static
    # metadata infoframe and a 10-bit link, so HDR cannot be passed through --
    # it has to be mapped down to SDR here. Pinning the target primaries and
    # transfer curve makes that conversion explicit rather than leaving it to
    # autodetection against a display that never advertises HDR.
    target-prim=bt.709
    target-trc=bt.1886
    tone-mapping=bt.2390
    gamut-mapping-mode=perceptual
    # Peak detection is a compute shader over every frame. On Kepler at 4K it
    # costs more than it returns, and it makes brightness pump on shot changes.
    # Use the stream's static MaxCLL/MaxFALL metadata instead.
    hdr-compute-peak=no
  '';
}
