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
}:

let
  pname = "wps-office";
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
    description = "Office suite, formerly Kingsoft Office";
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
  ];

  dontWrapQtApps = true;

  stripAllList = [ "opt" ];

  runtimeDependencies = map lib.getLib [
    cups
    dbus
    pango
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
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out

    cp -r opt $out
    cp -r usr/{bin,share} $out

    for i in $out/bin/*; do
      substituteInPlace $i \
        --replace-fail /opt/kingsoft/wps-office $out/opt/kingsoft/wps-office
    done

    for i in $out/share/applications/*; do
      substituteInPlace $i \
        --replace-fail /usr/bin $out/bin
    done

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
        --replace-fail '[ $haveConf -eq 1 ] &&' '[ ! $currentMode ] ||'
    done
  '';
}
