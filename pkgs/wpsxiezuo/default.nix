{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  binutils,
  gnutar,
  alsa-lib,
  at-spi2-core,
  cups,
  dbus,
  gtk3,
  libgbm,
  libnotify,
  libsecret,
  libxkbcommon,
  nss,
  pango,
  pulseaudio,
  udev,
  libbsd,
  libXScrnSaver,
  libXxf86vm,
  libxtst,
  libxv,
}:

let
  pname = "wpsxiezuo";
  sources = import ./sources.nix;
  version = sources.version;

  src = fetchurl {
    name = "${pname}-${version}-${stdenv.hostPlatform.system}.deb";
    inherit (sources.${stdenv.hostPlatform.system}) url hash;
  };

  meta = {
    description = "WPS collaboration and communication client";
    homepage = "https://xz.wps.cn";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    hydraPlatforms = [ ];
    license = lib.licenses.unfree;
    maintainers = with lib.maintainers; [ ];
    mainProgram = "xiezuo";
  };
in
stdenv.mkDerivation {
  inherit
    pname
    version
    src
    meta
    ;

  nativeBuildInputs = [
    autoPatchelfHook
    binutils
    gnutar
  ];

  buildInputs = [
    alsa-lib
    at-spi2-core
    gtk3
    libgbm
    libnotify
    libsecret
    libxkbcommon
    nss
    pulseaudio
    libbsd
    libXScrnSaver
    libXxf86vm
    libxtst
    libxv
  ];

  runtimeDependencies = map lib.getLib [
    at-spi2-core
    cups
    dbus
    gtk3
    libgbm
    libnotify
    libsecret
    nss
    pango
    pulseaudio
    udev
    libbsd
    libXScrnSaver
    libXxf86vm
    libxtst
    libxv
  ];

  dontStrip = true;

  unpackPhase = ''
    runHook preUnpack

    ar x $src
    tar -xf data.tar.xz

    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r opt $out
    cp -r usr/share $out/share

    if [ -d "$out/share/doc/kingsoft-xiezuo" ]; then
      mv "$out/share/doc/kingsoft-xiezuo" "$out/share/doc/xiezuo"
    fi

    # Replace chrome_crashpad_handler with a small IPC-compatible stub.
    rm -f $out/opt/xiezuo/chrome_crashpad_handler
    $CC -O2 -o $out/opt/xiezuo/chrome_crashpad_handler ${../wps365-cn/crashpad-handler-stub.c}

    mkdir -p $out/bin
    cat > $out/bin/xiezuo <<'EOF'
    #!${stdenv.shell}
    set -euo pipefail
    config_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/xiezuo"
    config_file="$config_dir/config.json"
    mkdir -p "$config_dir"
    if [ ! -f "$config_file" ]; then
      echo '{}' > "$config_file"
    fi
    cd "@out@/opt/xiezuo"
    exec "@out@/opt/xiezuo/xiezuo" --no-sandbox "$@"
    EOF
    substituteInPlace $out/bin/xiezuo --replace-warn "@out@" "$out"
    chmod +x $out/bin/xiezuo

    if [ -f "$out/share/applications/xiezuo.desktop" ]; then
      if grep -q 'Exec=/opt/xiezuo/xiezuo --no-sandbox --disable-gpu-sandbox --disable-setuid-sandbox --package-format=deb %U' "$out/share/applications/xiezuo.desktop"; then
        substituteInPlace "$out/share/applications/xiezuo.desktop" \
          --replace-fail 'Exec=/opt/xiezuo/xiezuo --no-sandbox --disable-gpu-sandbox --disable-setuid-sandbox --package-format=deb %U' "Exec=$out/bin/xiezuo %U"
      elif grep -q 'Exec=/opt/xiezuo/xiezuo' "$out/share/applications/xiezuo.desktop"; then
        substituteInPlace "$out/share/applications/xiezuo.desktop" \
          --replace-fail 'Exec=/opt/xiezuo/xiezuo' "Exec=$out/bin/xiezuo"
      elif grep -q 'Exec=/usr/bin/xiezuo' "$out/share/applications/xiezuo.desktop"; then
        substituteInPlace "$out/share/applications/xiezuo.desktop" \
          --replace-fail 'Exec=/usr/bin/xiezuo' "Exec=$out/bin/xiezuo"
      fi
    fi

    local qt_tools="$out/opt/xiezuo/resources/qt-tools"
    if [ -f "$qt_tools/libmini_ipc.so" ]; then
      mv "$qt_tools/libmini_ipc.so" "$qt_tools/libmini_ipc_real.so"
      $CC -shared -fPIC -O2 \
        -o "$qt_tools/libmini_ipc.so" \
        ${../wps365-cn/libmini_ipc_stub.c} \
        -ldl -lpthread
    fi

    runHook postInstall
  '';

  preFixup = ''
    if [ -f "$out/opt/xiezuo/xiezuo" ]; then
      if ! patchelf --print-needed "$out/opt/xiezuo/xiezuo" | grep -qx libudev.so.1; then
        patchelf --add-needed libudev.so.1 "$out/opt/xiezuo/xiezuo"
      fi
    fi
  '';
}
