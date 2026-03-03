{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  binutils,
  gnutar,
  # wpsoffice dependencies
  alsa-lib,
  libjpeg,
  libtool,
  libxkbcommon,
  nss,
  nspr,
  udev,
  gtk3,
  libgbm,
  libusb1,
  unixODBC,
  libmysqlclient,
  libsForQt5,
  libxv,
  libxtst,
  libxdamage,
  # wpsoffice runtime dependencies
  cups,
  dbus,
  pango,
  pulseaudio,
  libbsd,
  libXScrnSaver,
  libXxf86vm,
  libva,
}:

let
  pname = "wps365-cn";
  sources = import ./sources.nix;
  version = sources.linux-version;

  src = fetchurl {
    url = sources.x86_64-linux.url;
    hash = sources.x86_64-linux.hash;
  };

  passthru = {
    updateScript = ./update.sh;
  };

  meta = {
    description = "WPS365 Office Suite";
    homepage = "https://www.wps.cn";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    hydraPlatforms = [ ];
    license = lib.licenses.unfree;
    maintainers = with lib.maintainers; [ ];
    changelog = "https://linux.wps.cn/wpslinuxlog";
    mainProgram = "wps";
  };
in
stdenv.mkDerivation {
  inherit
    pname
    version
    src
    passthru
    meta
    ;

  nativeBuildInputs = [
    autoPatchelfHook
    binutils
    gnutar
  ];

  buildInputs = [
    alsa-lib
    libjpeg
    libtool
    libxkbcommon
    nspr
    udev
    gtk3
    libgbm
    libusb1
    unixODBC
    libsForQt5.qtbase
    libxdamage
    libxtst
    libxv
    pulseaudio
    libbsd
    libXScrnSaver
    libXxf86vm
  ];

  dontWrapQtApps = true;

  dontStrip = true;

  runtimeDependencies = map lib.getLib [
    cups
    dbus
    pango
    pulseaudio
    libbsd
    libXScrnSaver
    libXxf86vm
    udev
    libva
  ];

  unpackPhase = ''
    # Unpack the .deb file
    ar x $src
    tar -xf data.tar.xz

    # Remove unneeded files
    rm -rf usr/share/{fonts,locale}
    rm -f usr/bin/misc
    rm -rf opt/kingsoft/wps-office/{desktops,INSTALL}
    rm -f opt/kingsoft/wps-office/office6/lib{peony-wpsprint-menu-plugin,bz2,jpeg,stdc++,gcc_s,odbc*,dbus-1}.so*
    # Remove bundled libraries that conflict with nix libs
    rm -f opt/kingsoft/wps-office/office6/nplibs/*.so*
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out

    cp -r opt $out
    cp -r usr/{bin,share} $out

    # Replace chrome_crashpad_handler with a no-op script.
    # The original handler crashes on NixOS because it cannot parse
    # the patched ELF headers, which then kills the main process.
    rm -f $out/opt/xiezuo/chrome_crashpad_handler
    cat > $out/opt/xiezuo/chrome_crashpad_handler <<'CRASHPAD_EOF'
    #!/bin/sh
    exec sleep infinity
    CRASHPAD_EOF
    chmod +x $out/opt/xiezuo/chrome_crashpad_handler

    for i in $out/bin/*; do
      substituteInPlace $i \
        --replace /opt/kingsoft/wps-office $out/opt/kingsoft/wps-office
    done

    for i in $out/share/applications/*; do
      substituteInPlace $i \
        --replace /usr/bin $out/bin
    done

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
    substituteInPlace $out/bin/xiezuo --replace "@out@" "$out"
    chmod +x $out/bin/xiezuo

    runHook postInstall
  '';

  preFixup = ''
    # dlopen dependency
    patchelf --add-needed libudev.so.1 $out/opt/kingsoft/wps-office/office6/addons/cef/libcef.so
    # libmysqlclient dependency
    patchelf --replace-needed libmysqlclient.so.18 libmysqlclient.so $out/opt/kingsoft/wps-office/office6/libFontWatermark.so
    patchelf --add-rpath ${libmysqlclient}/lib/mariadb $out/opt/kingsoft/wps-office/office6/libFontWatermark.so
    # fix et/wpp/wpspdf failure to launch with no mode configured
    for i in $out/bin/*; do
      substituteInPlace $i \
        --replace '[ $haveConf -eq 1 ] &&' '[ ! $currentMode ] ||'
    done
  '';
}
