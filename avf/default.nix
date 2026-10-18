{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  base = pkgs.fetchgit {
    url = "https://android.googlesource.com/platform/packages/modules/Virtualization/";
    rev = "android-16.0.0_r3";
    hash = "sha256-boWayfOI88ejnXZ5yQzYdSuMANJLB5/Wd30ZWtsXuHw=";
  };
  extraPkgs = pkgs.callPackage ./pkgs.nix { inherit base; };

  serialDevice = "ttyS0";

  mkService = name: {
    serviceConfig = {
      ExecStart = "${
        lib.getExe extraPkgs.android_virt.${name}
      } --grpc-port-file /mnt/internal/debian_service_port";
      Type = "simple";
      Restart = "on-failure";
      RestartSec = 1;
      User = "root";
      Group = "root";
      StandardOutput = "journal";
      StandardError = "journal";
    };
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "network.target"
      "mnt-internal.mount"
    ];

    restartIfChanged = false;
  };

  vmConfig = pkgs.formats.json { };

  cfg = config.avf;
in

with lib;
{
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  options = {
    avf = {
      vmConfig = mkOption {
        description = "VM config for AVF";
        default = { };
        type = vmConfig.type;
      };

      defaultUser = mkOption {
        description = "Default user to create";
        type = types.str;
        default = "droid";
      };

      extraFiles = mkOption {
        description = "Extra files to include in the image";
        type = types.attrsOf types.path;
        default = { };
        example = {
          "README.md" = ../README.md;
        };
      };

      enableConfigReplace = mkEnableOption "vm_config.json replace (WARNING ALPHA MAY BRICK INSTALL)";
      useGenericKernel = mkEnableOption "use nixpkgs' own kernel instead of the AVF-patched 6.1 (see below; on Android 17 this is the only option that builds)";
      enableGraphics = mkEnableOption "graphics support (Weston + gfxstream)" // {
        default = true;
      };
      directBoot = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Hand the kernel and initrd straight to crosvm via `vm_config.json`,
          the way Android 17's Terminal app does for its own images.

          Up to Android 16 the Terminal app chainloaded `u-boot` from the host,
          which then booted the ESP in `efi_part`, so a bootloader had to be
          installed into the image. Android 17 boots the payload kernel
          directly and executes `/sbin/init` in the guest, which makes the
          installed bootloader dead weight.

          Turning this off restores the Android 16 behaviour (u-boot
          chainload, `/mnt/internal`, the guest daemons that need it) for
          devices still on an older release.
        '';
      };
      enableAudio = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Ask the host for a virtio-snd device by adding an `audio` block to
          `vm_config.json`, and load `snd_virtio` in the initrd.

          Untested. The host side is gated on crosvm being built with
          `paravirtualized_devices`; when it is not, crosvm logs "Audio
          configuration not supported" and ignores the request. The same flag
          gates display, which is likewise not known to work.
        '';
      };
      ttydExtraArgs = mkOption {
        description = "Extra arguments to pass to ttyd before -W";
        type = types.listOf types.str;
        default = [ ];
        example = [
          "-t"
          "fontSize=14"
          "-t"
          "fontFamily=monospace"
        ];
      };
    };
  };

  config = {
    avf.vmConfig = {
      # VM name must be "debian" for display output to work
      name = "debian";
      disks = [
        {
          partitions = [
            {
              label = "ESP";
              path = "$PAYLOAD_DIR/efi_part";
              writable = true;
              guid = "{efi_part_guid}";
            }
            {
              label = "nixos";
              path = "$PAYLOAD_DIR/root_part";
              writable = true;
              guid = "{root_part_guid}";
            }
          ];
          writable = true;
        }
      ];
      sharedPath = [
        {
          sharedPath = "/storage/emulated";
        }
        {
          sharedPath = "$APP_DATA_DIR/files";
        }
      ];
      protected = false;
      cpu_topology = "match_host";
      platform_version = "~1.0";
      memory_mib = 4096;
      debuggable = true;
      console_out = true;
      console_input_device = "ttyS0";
      network = true;
      auto_memory_balloon = true;
      gpu = {
        backend = "2d";
      };

      # Direct boot: crosvm is handed the payload's kernel and initrd and
      # `params` is the whole kernel command line, so everything
      # `boot.kernelParams` would otherwise have contributed through the
      # installed bootloader has to be spelled out here. The `init=` half is
      # what nixos' own systemd-boot builder writes for every entry, and for
      # a systemd-initrd system `$toplevel/init` is a copy of systemd itself
      # (see system/activation/top-level.nix). `root=` is deliberately left
      # alone: systemd defaults to `fstab`, and nixpkgs generates the initrd's
      # fstab from `fileSystems."/"`, which points at
      # /dev/disk/by-label/nixos.
      kernel = mkIf cfg.directBoot "$PAYLOAD_DIR/vmlinuz";
      initrd = mkIf cfg.directBoot "$PAYLOAD_DIR/initrd.img";
      params = mkIf cfg.directBoot "init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams}";

      # The app only surfaces the console once this is set, which is the only
      # window into a failed boot.
      connect_console = mkIf cfg.directBoot true;

      # The 60s default is short for a first boot of a cold NixOS on a phone.
      boot_timeout_secs = mkIf cfg.directBoot 180;

      # crosvm serves audio as a vhost-user `sound` device fronted by
      # crosvm_vu_snd talking to Android's AudioFlinger, and only when the
      # image asks for one.
      audio = mkIf cfg.enableAudio {
        microphone = false;
        speaker = true;
      };
    };

    /*
      services.ttyd = {
        enable = true;
        enableSSL = true;
        caFile = = "/mnt/internal/ca.crt";
        keyFile = "/etc/ttyd/server.key";
        clientOptions = [ "disableLeaveAlert=true" ];
        certFile = "/etc/ttyd/server.ct";
        entrypoint = [ "${pkgs.shadow}/bin/login" "-f" "${cfg.defaultUser}" ];
        writeable = true;
      };
    */

    # Lets systemd tolerate a partition whose GPT type is not SD_GPT_ESP.
    #
    # Only needed on the Android 16 path, where the guest boots through
    # u-boot and systemd has to find the ESP in the disk crosvm hands it.
    # Under direct boot nothing on the device ever calls into find-esp: the
    # kernel and initrd are handed straight to crosvm and `/boot` is an
    # ordinary fstab entry.
    #
    # It also is not free. A patched derivation is in no binary cache, and
    # this one is used twice -- the toplevel and, because the initrd is a
    # systemd initrd, the initrd's systemd as well -- so every machine that
    # builds an Android 17 image compiles a systemd that cache.nixos.org
    # already has an unpatched copy of. Dropping it here is what makes
    # systemd substitutable again.
    systemd.package = mkIf (!cfg.directBoot) (
      pkgs.systemd.overrideAttrs (a: {
        patches = a.patches ++ [
          ./systemd-esp-type-ignore.patch
        ];
      })
    );

    systemd.services.ttyd = {
      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            "${lib.getExe extraPkgs.ttyd}"
            "--ssl"
            "--ssl-cert"
            "/etc/ttyd/server.crt"
            "--ssl-key"
            "/etc/ttyd/server.key"
          ]
          # The CA is how ttyd verified the Terminal app's client certificate,
          # and it arrived through /mnt/internal, which Android 17 no longer
          # exposes. Without it ttyd serves TLS but does not ask for a client
          # certificate, which is fine: the app's WebView calls
          # `handler.proceed()` on any SSL error anyway ("ttyd uses
          # self-signed certificate"). TLS itself has to stay, because the
          # app decides http-vs-https from `terminalAddress.key.isNullOrEmpty()`
          # and the mDNS discovery path below never sets a key.
          ++ lib.optionals (!cfg.directBoot) [
            "--ssl-ca"
            "/mnt/internal/ca.crt"
          ]
          ++ [
            "-t"
            "disableLeaveAlert=true"
          ]
          ++ cfg.ttydExtraArgs
          ++ [
            "-W"
            "${config.services.ttyd.entrypoint}"
            "-f"
            cfg.defaultUser
          ]
        );
        Type = "simple";
        Restart = "always";
        User = "root";
        Group = "root";
      };

      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "network.target"
      ]
      ++ lib.optionals (!cfg.directBoot) [ "mnt-internal.mount" ];

      restartIfChanged = false;
    };

    # How the app finds ttyd. TerminalApp's VmController picks between two
    # paths: it only looks for a vsock bridge when the image's `build_id`
    # parses as a number >= 5106 (InstalledImage.BuildInfo), and otherwise
    # registers an NsdManager query for a service literally named `ttyd` of
    # type `_http._tcp`, then connects to whatever address it resolves to.
    # finish.nix writes `nixos_avf/<system>/<version>-0-<date>`, which parses
    # to build_id 0, so the mDNS path is the one in play. That is the same
    # discovery the pre-Android-17 Terminal used, which is why avahi stays.
    systemd.services.avahi_ttyd = {
      description = "avahi_TTYD";

      after = [
        "ttyd.service"
        "avahi-daemon.socket"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.avahi}/bin/avahi-publish-service ttyd _http._tcp 7681";
        Type = "simple";
        Restart = "always";
        User = "root";
        Group = "root";
      };
    };

    services.avahi = {
      enable = true;
      # Sometimes during startup, Terminal will discover only the IPv6 address
      # and then only whitelist that one for GRPC.
      # Remove once this is solved. See #5
      ipv6 = false;
      publish = {
        enable = true;
        userServices = true;
      };
    };

    system.build.avfImage = pkgs.callPackage ./finish.nix {
      raw_disk_image = import "${pkgs.path}/nixos/lib/make-disk-image.nix" {
        inherit pkgs lib config;

        partitionTableType = "efi";
        copyChannel = false;
        memSize = "2048";
        # make sure image can be used
        additionalSpace = "2G";
      };

      vm_config = config.system.build.vmConfig;
      extraFiles = cfg.extraFiles;

      # Names here are what `avf.vmConfig` refers to, so the two lists have to
      # agree; the guest's bootloader is bypassed entirely on Android 17.
      payloadFiles = lib.optionals cfg.directBoot [
        {
          name = "vmlinuz";
          src = "${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile}";
        }
        {
          name = "initrd.img";
          src = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
        }
      ];
    };

    system.build.vmConfig = vmConfig.generate "vm_config.json" cfg.vmConfig;

    nix.settings.substituters = [
      "https://nix-community.cachix.org"
    ];

    nix.settings.trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];

    boot.growPartition = true;
    boot.loader.systemd-boot.enable = true;
    boot.initrd.systemd.enable = true;
    boot.loader.systemd-boot.extraInstallCommands = mkIf (cfg.enableConfigReplace) ''
      # update vm_config if on live machine
      if [ -e /mnt/internal/linux ]; then
        ${pkgs.coreutils}/bin/cp -v ${config.system.build.vmConfig} /tmp/vm_config.json.new
        ${pkgs.gnused}/bin/sed -i "s/{efi_part_guid}/$(${pkgs.util-linux}/bin/sfdisk --part-uuid /dev/vda 1)/g" /tmp/vm_config.json.new
        ${pkgs.gnused}/bin/sed -i "s/{root_part_guid}/$(${pkgs.util-linux}/bin/sfdisk --part-uuid /dev/vda 2)/g" /tmp/vm_config.json.new
        ${pkgs.coreutils}/bin/mv -v /tmp/vm_config.json.new /mnt/internal/linux/vm_config.json
      fi
    '';

    # image building needs to know what device to install bootloader on
    boot.loader.grub.device = "/dev/vda";
    # Faster boot. User can't access bootloader currently anyways (?)
    boot.loader.timeout = 0;

    # avf patches only available for 6.1 right now
    #
    # WARNING: as of nixpkgs 26.05 these patches no longer apply, so leaving
    # useGenericKernel off makes the kernel *fail to build* rather than merely
    # be uncached. `arm64-balloon.patch` is a six-patch series and its last
    # sub-patch fails:
    #
    #   Reversed (or previously applied) patch detected!  Assume -R? [n]
    #   1 out of 1 hunk ignored -- saving rejects to file
    #   drivers/virtio/virtio_balloon.c.rej
    #
    # That sub-patch only deletes the line
    # `__virtio_clear_bit(vdev, VIRTIO_F_ACCESS_PLATFORM);` from
    # virtballoon_validate, and its context was invalidated by the upstream
    # commit that added `__virtio_clear_bit(vdev,
    # VIRTIO_RING_F_INDIRECT_DESC);` immediately above it ("Disable indirect
    # descriptors to avoid memory allocation in virtqueue_add during page
    # reporting"). The AOSP series is still being carried against an older
    # 6.1. `patchFlags = [ "-N" ]` would silence it, since patch(1) reads the
    # unmatchable hunk as already applied; that is deliberately not done here
    # because it also hides real breakage in the other five sub-patches, and
    # because the line it wants gone is still present -- so `-N` would leave
    # the kernel disabling VIOMMU for the balloon device, which is the one
    # thing the sub-patch exists to undo.
    #
    # What the patches would buy, on an Android 17 host, is close to nothing:
    #
    #   * The balloon patch adds mem_relinquish, which is how a guest hands
    #     free pages back to Android. But Android 17 folded
    #     storage_balloon_agent into linux_vm_manager, which is Soong and so
    #     unbuildable from Nix -- see the directBoot block above. Without the
    #     host-side agent there is nothing asking for pages to be
    #     relinquished, so `auto_memory_balloon` is inert either way and the
    #     guest driver changes nothing.
    #   * The cpufreq patch only makes the guest observe the host's CPU
    #     frequencies, which is cosmetic.
    #
    # Dropping them also makes the kernel substitutable: a stock nixpkgs
    # 6.1 (and the 6.18 that `useGenericKernel` actually resolves to on
    # 26.05) is in cache.nixos.org, whereas neither cache.nixos.org nor
    # nix-community.cachix.org has the patched one. So the patched path means
    # compiling a kernel on whatever machine builds the image, for a
    # capability that is already gone.
    #
    # Android's own AVF guest kernels are prebuilt for 6.1, 6.12 and 6.18
    # (`kernel/prebuilts/common-modules/virtual-device/` in the platform
    # manifest), so the newer default is a version the hypervisor is known
    # to work with.
    boot.kernelPackages = mkIf (!cfg.useGenericKernel) pkgs.linuxPackages_6_1;

    boot.kernelPatches = mkIf (!cfg.useGenericKernel) [
      {
        name = "avf-ballon";
        patch = "${base}/build/debian/kernel/patches/avf/arm64-balloon.patch";
        ${
          if lib.versionAtLeast lib.trivial.release "25.05" then
            "structuredExtraConfig"
          else
            "extraStructuredConfig"
        } =
          with lib.kernel; {
            SND_VIRTIO = module;
            SND = yes;
            SOUND = yes;
          };
      }
      {
        name = "avf-cpufreq";
        patch = "${base}/build/debian/kernel/patches/avf/virtual-cpufreq.patch";
        ${
          if lib.versionAtLeast lib.trivial.release "25.05" then
            "structuredExtraConfig"
          else
            "extraStructuredConfig"
        } =
          with lib.kernel;
          {
            CPU_FREQ = yes;
            IKCONFIG = yes;
            IKCONFIG_PROC = yes;
          }
          // (
            if pkgs.stdenv.targetPlatform.isAarch64 then
              {
                ANDROID_V_CPUFREQ_VIRT = yes;
              }
            else
              { }
          );
      }
    ];

    boot.kernelParams = [
      "console=tty1"
      "console=${serialDevice}"
    ];

    boot.kernelModules = [
      "vhost_vsock"
    ]
    ++ lib.optionals cfg.enableGraphics [ "virtio_gpu" ]
    # The AVF balloon patch builds `snd_virtio` as a module, so nothing
    # binds it unless something loads it.
    ++ lib.optionals cfg.enableAudio [ "snd_virtio" ];

    fileSystems = {
      "/" = {
        device = "/dev/disk/by-label/nixos";
        autoResize = true;
        fsType = "ext4";
      };
      "/boot" = {
        device = "/dev/disk/by-label/ESP";
        fsType = "vfat";
      };

      # Android 17 stopped exposing /mnt/internal (the app's own data
      # directory, shared in as virtiofs), so there is nothing to mount and a
      # virtiofs mount unit for it would fail and take `local-fs.target` with
      # it. Everything that used to live there -- the Terminal app's CA, the
      # guest daemons' --grpc-port-file -- went with it.
      "/mnt/internal" = mkIf (!cfg.directBoot) {
        device = "internal";
        fsType = "virtiofs";
      };
      "/mnt/shared" = {
        device = "android";
        fsType = "virtiofs";
      };
      /*
        "/mnt/backup" = {
          device = "/dev/vdb";
          fsType = "virtiofs";
        };
      */
    };

    # from Virtualization/guest/storage_balloon_agent/debian/service
    #
    # All three of these are inert under direct boot, and not only because
    # /mnt/internal is gone:
    #
    #   * they are told which port to talk to with `--grpc-port-file
    #     /mnt/internal/debian_service_port`;
    #   * Android 17 consolidated all three into `linux_vm_manager`, which is
    #     built with Soong rather than Cargo, so there is no Rust crate left
    #     for mkRustPkg to build even though the other three are still Cargo
    #     in the tree.
    #
    # The cost is that the app can no longer power the guest off, forward
    # ports, or reclaim memory through the balloon agent, and there is no
    # guest agent for the port-notification UI. `poweroff` from inside is the
    # supported way to stop the VM.

    systemd.services.storage_balloon_agent = mkIf (!cfg.directBoot) (mkService "storage_balloon_agent");

    # from Virtualization/guest/forwarder_guest_launcher/debian/service

    systemd.services.forwarder_guest_launcher = mkIf (!cfg.directBoot) (
      mkService "forwarder_guest_launcher"
      // {
        path = [
          extraPkgs.android_virt.forwarder_guest
          pkgs.bcc
          "/run/current-system/sw"
        ];
      }
    );

    # from Virtualization/guest/shutdown_runner/debian/service

    systemd.services.shutdown_runner = mkIf (!cfg.directBoot) (mkService "shutdown_runner");

    services.zram-generator = {
      enable = true;
      settings = {
        "zram0" = {
          zram-size = "ram / 4";
        };

        "" = {
          compression-algorithm = "zstd";
        };
      };
    };

    users.users.${cfg.defaultUser} = {
      isNormalUser = true;
      extraGroups = [
        "${cfg.defaultUser}"
        "wheel"
      ]
      ++ lib.optionals cfg.enableGraphics [
        "video"
        "render"
        "seat"
      ];
      initialHashedPassword = "";
    };
    users.groups.${cfg.defaultUser} = { };
    security.sudo.wheelNeedsPassword = false;

    # Only ever reached from forwarder_guest_launcher's `path`, which is gated on
    # !directBoot. Under direct boot this is bcc plus its LLVM stack
    # installed into the guest for nothing -- substitutable, so no build
    # cost, but a large slice of a root filesystem that has 4 GiB to work
    # with.
    programs.bcc.enable = mkIf (!cfg.directBoot) true;

    /*
      programs.bash.interactiveShellInit = ''
        # Show title of current running command
        trap 'echo -ne "\e]0;\$BASH_COMMAND\007"' DEBUG
      '';
    */

    environment.systemPackages = mkIf cfg.enableGraphics (
      with pkgs;
      [
        mesa
        weston
        libdrm
      ]
    );

    # Enable hardware acceleration
    hardware.graphics.enable = mkIf cfg.enableGraphics true;

    # Enable seatd for seat management (required for DRM access in user services)
    services.seatd.enable = mkIf cfg.enableGraphics true;

    environment.variables = mkIf cfg.enableGraphics {
      VK_ICD_FILENAMES = "${pkgs.mesa}/share/vulkan/icd.d/gfxstream_vk_icd.${pkgs.stdenv.hostPlatform.uname.processor}.json";
      MESA_LOADER_DRIVER_OVERRIDE = "zink";
      MESA_VK_WSI_DEBUG = "sw,linear";
      WAYLAND_DISPLAY = "wayland-0";
      DISPLAY = ":0";
    };

    systemd.user.services.weston = mkIf cfg.enableGraphics {
      description = "Weston Wayland compositor";

      requires = [ "weston.socket" ];
      after = [ "weston.socket" ];
      wantedBy = [ "default.target" ];

      serviceConfig = {
        Type = "notify";
        ExecStart = "${pkgs.weston}/bin/weston --backend=drm --modules=systemd-notify.so --xwayland --shell=kiosk-shell.so --continue-without-input";
        StandardOutput = "journal";
        StandardError = "journal";
        Restart = "on-failure";
      };

      environment = {
        LIBGL_DRIVERS_PATH = "${pkgs.mesa.drivers}/lib/dri";
        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
      };
    };

    systemd.user.sockets.weston = mkIf cfg.enableGraphics {
      description = "Weston Wayland compositor socket";

      socketConfig = {
        ListenStream = "%t/wayland-0";
      };

      wantedBy = [ "sockets.target" ];
    };

    systemd.network.enable = true;
    networking.useNetworkd = true;
    networking.dhcpcd.enable = false;
    services.resolved.dnssec = "false";
    networking.useDHCP = true;
    networking.firewall.enable = true; # default
    networking.nftables.enable = true;
    networking.firewall.allowedTCPPorts = [ 7681 ];
  };
}
