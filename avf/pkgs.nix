{
  base,
  lib,
  ttyd,
  rustPlatform,
  protobuf,
  libwebsockets,
}:
let

  mkRustPkg =
    name: lock: extra:
    rustPlatform.buildRustPackage (
      {
        inherit name;

        RUSTFLAGS = "-C linker=gcc";

        # see https://github.com/NixOS/nixpkgs/issues/145726
        # TODO: disable when cross-compling
        prePatch = ''
          rm .cargo/config.toml
        '';

        src = base;
        setSourceRoot = "sourceRoot=$(echo */guest/${name})";

        nativeBuildInputs = [
          protobuf
        ];

        postPatch = ''
          ln -s ${lock} Cargo.lock
        '';

        cargoLock = {
          lockFile = lock;
        };

        meta = {
          mainProgram = name;
        };
      }
      // extra
    );
in
{
  # Kept patched even though it makes ttyd unbuildable from a binary cache,
  # because ttyd is how a first boot is reached: the Terminal app finds
  # it over mDNS and connects to https://<vm>:7681. That is worth one
  # small local build. `xtermjs_a11y.patch` is an accessibility fix to the
  # bundled xterm.js, and the client_cert patch below has been inoperative
  # since libwebsockets 4.3.6 stopped needing the `--ssl-ca` bitmask fix
  # -- it only matters on the !directBoot path, where /mnt/internal
  # provides the CA.
  ttyd =
    (ttyd.override {
      libwebsockets = libwebsockets.overrideAttrs (
        a:
        lib.optionalAttrs (lib.strings.versionOlder a.version "4.3.6") {
          patches = [
            "${base}/build/debian/ttyd/client_cert.patch"
          ];
        }
      );
    }).overrideAttrs
      (a: {
        patches = [
          "${base}/build/debian/ttyd/xtermjs_a11y.patch"
        ];
      });

  android_virt = lib.recurseIntoAttrs {
    forwarder_guest = mkRustPkg "forwarder_guest" ./forwarder_guest_Cargo.lock { };
    forwarder_guest_launcher =
      mkRustPkg "forwarder_guest_launcher" ./forwarder_guest_launcher_Cargo.lock
        {
          patches = [
            ./guest-tcpstates.patch
          ];
        };
    shutdown_runner = mkRustPkg "shutdown_runner" ./shutdown_runner_Cargo.lock { };
    storage_balloon_agent = mkRustPkg "storage_balloon_agent" ./storage_balloon_agent_Cargo.lock
        {
          patches = [
            ./fix-reserved_clusters-storage_balloon_agent.patch
          ];
        };
  };
}
