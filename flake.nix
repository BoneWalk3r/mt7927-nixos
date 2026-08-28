{
  description = "NixOS hardware support for MediaTek MT7927 / MT6639 (Filogic 380) WiFi 7 and Bluetooth. Edited to work on BoneWalk3r's system.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Upstream source for patches and firmware extraction scripts
    mediatek-mt7927-dkms = {
      url = "github:jetm/mediatek-mt7927-dkms";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, mediatek-mt7927-dkms }:

    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      repoSrc = mediatek-mt7927-dkms;

      # Check if we have saved versions. If not, fall-back to the hardcoded version.
      versions =

        if builtins.pathExists ./versions.json then
          builtins.fromJSON (builtins.readFile ./versions.json)
        else
          {
            mt76KVer = "7.0";
            mt76Hash = "sha256-7TjYHhJdD67P3lquusrjjVtUIUzhLPtA5Oy7tc82gYA=";
          };

      # 2. Parse metadata from the DKMS repo's PKGBUILD for ASUS firmware
      pkgbuild = builtins.readFile "${repoSrc}/PKGBUILD";

      driverFilename =
        let
          m = builtins.match ".*_driver_filename='([^']+)'.*" pkgbuild;
        in
        if m != null then builtins.head m else "DRV_WiFi_MTK_MT7925_MT7927_TP_W11_64_V5603998_20250709R.zip";

      driverSha256Hex =
        let
          m = builtins.match ".*_driver_sha256='([a-f0-9]+)'.*" pkgbuild;
        in
        if m != null then builtins.head m else "b377fffa28208bb1671a0eb219c84c62fba4cd6f92161b74e4b0909476307cc8";

      # 3. Patch lists
      # These need to be maintained.
      # As patches are integrated into the main kernel/upstream, you'll need to
      # disable their application by naming them here.
      wifiPatches = let blacklist = [
            "mt7927-wifi-01-clean-up-dma-on-probe-failure.patch"
            "mt7927-wifi-02-fix-stale-pointer-comparisons-in-changev.patch"
            "mt7927-wifi-05-populate-eht-320mhz-mcs-map-in-starec.patch"
            "mt7927-wifi-06-advertise-eht-320mhz-capabilities-for-6g.patch"
            "mt7927-wifi-08-add-mt7927-firmware-paths.patch"
            "mt7927-wifi-09-use-irqmap-for-chip-specific-interrupt-h.patch"
            "mt7927-wifi-10-disable-aspm-and-runtime-pm-for-mt7927.patch"
            "mt7927-wifi-11-replace-ismt7925-with-isconnac3.patch"
            "mt7927-wifi-12-use-link-specific-removal-for-non-mld-st.patch"
            "mt7927-wifi-13-tolerate-inactive-bss-deactivation.patch"
            "mt7927-wifi-14-add-mt7927-wfsys-reset-support.patch"
            "mt7927-wifi-16-switch-dma-init-to-common-mt792x-queue-h.patch"
            "mt7927-wifi-17-add-mt7927-specific-pcie-dma-support.patch"
            "mt7927-wifi-18-sync-mt7927-bss-band-assignment.patch"
            "mt7927-wifi-23-keep-tx-ba-state-in-the-primary-wcid.patch"
            # add others as discovered
          ];

        in
          map (n: "${repoSrc}/${n}")
            (builtins.filter (n: !(builtins.elem n blacklist))
              (versions.wifiPatches or []));


      btPatches = let blacklist = [
            # add others as discovered
          ];

        in
          map (n: "${repoSrc}/${n}")
            (builtins.filter (n: !(builtins.elem n blacklist))
              (versions.btPatches or []));


      # 4. Fetch kernel source
      #linuxDrivers = pkgs.fetchzip {
        #url = "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-${versions.mt76KVer}.tar.gz";
        #hash = versions.mt76Hash;
      #};

      # 5. Firmware source from ASUS
      asusZip = pkgs.fetchurl {
        url = "https://dlcdnets.asus.com/pub/ASUS/mb/08WIRELESS/${driverFilename}";
        hash = "sha256:${driverSha256Hex}";
        name = "asus-mt7927-driver.zip";
      };

      # Generator function for kernel-version-specific packages
      mkMt7927 = kernel:

        let
          isClang = kernel.stdenv.cc.isClang or false;
          kernelBuild = "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build";
          makeFlags = if isClang then "LLVM=1 CC=clang" else "";

        in
        rec {
          firmware = kernel.stdenv.mkDerivation {
            pname = "mediatek-mt7927-firmware";
            version = "2.1";
            dontUnpack = true;
            nativeBuildInputs = [
              pkgs.libarchive
              pkgs.python3
            ];

            buildPhase = ''
              runHook preBuild
              bsdtar -xf ${asusZip} mtkwlan.dat
              python3 ${repoSrc}/extract_firmware.py mtkwlan.dat firmware/
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              install -Dm644 firmware/BT_RAM_CODE_MT6639_2_1_hdr.bin \
                "$out/lib/firmware/mediatek/mt7927/BT_RAM_CODE_MT6639_2_1_hdr.bin"

              install -Dm644 firmware/BT_RAM_CODE_MT6639_2_1_hdr.bin \
                "$out/lib/firmware/mediatek/mt6639/BT_RAM_CODE_MT6639_2_1_hdr.bin"

              install -Dm644 firmware/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin \
                "$out/lib/firmware/mediatek/mt7927/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin"

              install -Dm644 firmware/WIFI_RAM_CODE_MT6639_2_1.bin \
                "$out/lib/firmware/mediatek/mt7927/WIFI_RAM_CODE_MT6639_2_1.bin"

              runHook postInstall
            '';

            meta.license = pkgs.lib.licenses.unfreeRedistributableFirmware;
          };

          wifi = kernel.stdenv.mkDerivation {
            pname = "mediatek-mt7927-wifi";

            version = "2.1";

            src = kernel.src;

            nativeBuildInputs = kernel.moduleBuildDependencies ++ [
              pkgs.python3
              pkgs.perl
              pkgs.kmod
            ];

            patches = wifiPatches;

            prePatch = "cd drivers/net/wireless/mediatek/mt76";

            postPatch = ''
              # Install upstream Kbuild files
              cp ${repoSrc}/mt76.Kbuild Kbuild
              cp ${repoSrc}/mt7925.Kbuild mt7925/Kbuild
              # Install compat header for kernels lacking airoha_offload.h
              mkdir -p compat/include/linux/soc/airoha
              cp ${repoSrc}/compat-airoha-offload.h \
                compat/include/linux/soc/airoha/airoha_offload.h
            '';

            buildPhase = ''
              runHook preBuild

              make -C ${kernelBuild} M=$(pwd) ${makeFlags} modules

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              modDir="$out/lib/modules/${kernel.modDirVersion}/extra/mt76"
              install -dm755 "$modDir/mt7925"
              install -m644 mt76.ko mt76-connac-lib.ko mt792x-lib.ko "$modDir/"
              install -m644 mt7925/*.ko "$modDir/mt7925/"

              runHook postInstall
            '';

          };


          bluetooth = kernel.stdenv.mkDerivation {
            pname = "mediatek-mt7927-bluetooth";

            version = "2.1";

            src = kernel.src;

            nativeBuildInputs = kernel.moduleBuildDependencies ++ [ pkgs.kmod ];

            patches = btPatches;

            prePatch = "cd drivers/bluetooth";

            buildPhase = ''
              runHook preBuild

              echo "obj-m += btusb.o btmtk.o" > Makefile
              make -C ${kernelBuild} M=$(pwd) ${makeFlags} modules

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              modDir="$out/lib/modules/${kernel.modDirVersion}/extra/bluetooth"
              install -dm755 "$modDir"
              install -m644 btusb.ko btmtk.ko "$modDir/"

              runHook postInstall
            '';

          };
        };

      defaultModules = mkMt7927 pkgs.linux;

    in
    {
      packages.x86_64-linux = {
        firmware = defaultModules.firmware;
        wifi = defaultModules.wifi;
        bluetooth = defaultModules.bluetooth;
        default = defaultModules.firmware;
        repo-src = repoSrc;
      };

      nixosModules.default = { config, pkgs, lib, ... }:
        let
          cfg = config.hardware.mediatek-mt7927;

          myKernel =
            pkgs.linuxPackages_latest.kernel.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                echo "Removing in-tree MediaTek mt76 driver"

                substituteInPlace drivers/net/wireless/mediatek/Makefile \
                  --replace-fail "obj-\$(CONFIG_MT76)" "" || true

                substituteInPlace drivers/net/wireless/mediatek/Kconfig \
                  --replace-fail "source \"drivers/net/wireless/mediatek/mt76/Kconfig\"" "" || true

                rm -rf drivers/net/wireless/mediatek/mt76
              '';
            });

          myKernelPackages = pkgs.linuxPackagesFor myKernel;
            /*pkgs.linuxPackagesFor (
              pkgs.linuxPackages_latest.kernel.override {
                structuredExtraConfig = with pkgs.lib.kernel; {
                  # Kill all the dependancies, or else Kmod loads in-tree drivers and breaks everything.
                  # mt76 base/shared
                  #MT76_CORE = lib.mkForce no;
                  #MT76_CONNAC_LIB = lib.mkForce no;

                  # mt792x shared
                  #MT792X_LIB = lib.mkForce no;
                  #MT7925_COMMON = lib.mkForce no;

                  # PCI/USB/SDIO MT792 drivers
                  MT7921E = lib.mkForce no;
                  MT7921S = lib.mkForce no;
                  MT7921U = lib.mkForce no;

                  MT7925E = lib.mkForce no;
                  MT7925U = lib.mkForce no;

                  # other connac users
                  #MT7915E = lib.mkForce no;
                  #MT7996E = lib.mkForce no;

                  #BT_HCIBTUSB_MTK = lib.mkForce no;
                  #BT_HCIBTUSB = lib.mkForce no;
                  #BT_MTK = lib.mkForce no;
                };
              }
            );*/

          builtModules = mkMt7927 myKernelPackages.kernel;

        in
        {
          options.hardware.mediatek-mt7927 = {
            enable = lib.mkEnableOption "MediaTek MT7927 / MT6639 WiFi and Bluetooth";
            enableWifi = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            enableBluetooth = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            disableAspm = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
          };

          config = lib.mkIf cfg.enable {
            hardware.firmware = [ builtModules.firmware ];
            boot.kernelPackages = myKernelPackages;

            boot.extraModulePackages =
              lib.optionals cfg.enableWifi [
                builtModules.wifi
              ]
              ++ lib.optionals cfg.enableBluetooth [
                builtModules.bluetooth
              ];

            boot.kernelModules =
              lib.optionals cfg.enableWifi [
                "mt7925e"
              ]
              ++ lib.optionals cfg.enableBluetooth [
                "btusb"
                "btmtk"
              ];

            boot.extraModprobeConfig = lib.mkIf cfg.disableAspm ''
              options mt7925e disable_aspm=1
            '';
          };
        };
    };
}
