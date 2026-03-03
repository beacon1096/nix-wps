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

    # Replace chrome_crashpad_handler with a minimal C stub.
    # The original handler crashes on NixOS because it cannot parse ELF
    # headers modified by autoPatchelfHook.  A simple "sleep infinity"
    # replacement causes the main process to hang because Chromium blocks
    # waiting for a crashpad IPC handshake that never comes.
    # This stub performs the handshake (recv 40 bytes, send 8 zero bytes
    # on --initial-client-fd) so the main process can proceed normally.
    rm -f $out/opt/xiezuo/chrome_crashpad_handler
    $CC -O2 -o $out/opt/xiezuo/chrome_crashpad_handler ${./crashpad-handler-stub.c}

    for i in $out/bin/*; do
      substituteInPlace $i \
        --replace /opt/kingsoft/wps-office $out/opt/kingsoft/wps-office
    done

    for i in $out/share/applications/*; do
      substituteInPlace $i \
        --replace /usr/bin $out/bin
    done

    # Fix xiezuo desktop file: point Exec to our wrapper script
    substituteInPlace $out/share/applications/xiezuo.desktop \
      --replace 'Exec=/opt/xiezuo/xiezuo --no-sandbox --disable-gpu-sandbox --disable-setuid-sandbox --package-format=deb %U' \
                'Exec='"$out"'/bin/xiezuo %U'

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

    # --- Fix 4: Replace libmini_ipc.so with a SIGSEGV-safe shim ---
    # The xiezuo Electron app uses ffi-napi to call init_helper() in
    # libmini_ipc.so, passing a JS callback wrapped as a C function pointer
    # via ffi.Callback().  The libffi closure's writable data page gets
    # freed/zeroed by the GC while the C++ recv-loop thread still holds the
    # raw pointer → the trampoline jumps to 0x0 → SIGSEGV.
    #
    # Fix: interpose a shim .so that:
    #   1. Renames the original to libmini_ipc_real.so
    #   2. Provides init_helper/uninit_helper/send_msg that delegate to the
    #      real lib but pass a stable C function pointer (not an ffi closure)
    #   3. The shim calls the ffi closure inside a SIGSEGV-recovery region
    #      (sigsetjmp/siglongjmp) so that if the closure IS freed, the crash
    #      is caught and the callback is silently disabled
    local qt_tools="$out/opt/xiezuo/resources/qt-tools"
    mv "$qt_tools/libmini_ipc.so" "$qt_tools/libmini_ipc_real.so"
    $CC -shared -fPIC -O2 \
      -o "$qt_tools/libmini_ipc.so" \
      ${./libmini_ipc_stub.c} \
      -ldl -lpthread

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
