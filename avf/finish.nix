{
  stdenv,
  raw_disk_image,
  vm_config,
  util-linux,
  pigz,
  e2fsprogs,
  dosfstools,
  lib,
  extraFiles,
  payloadFiles,
}:
stdenv.mkDerivation {
  name = "avf_image.tar.gz";

  nativeBuildInputs = [
    util-linux
    pigz
    e2fsprogs
    dosfstools
  ];

  dontUnpack = true;
  dontBuild = true;
  installPhase = ''
    diskImage=$(echo ${raw_disk_image}/*.img)

    OFFSETS=($(sfdisk -l $diskImage -o Start,Sectors | tail -n 2 | grep -o "[0-9]*"))

    echo "nixos_avf/${
      lib.replaceStrings [ "-" ] [ "_" ] stdenv.targetPlatform.system
    }/${lib.trivial.version}-0-$(date)" > build_id

    # bs=512 -> sector size is 512, skip=start sector, count=size in sectors
    dd if=$diskImage of=efi_part bs=512 skip="''${OFFSETS[0]}" count="''${OFFSETS[1]}"
    dd if=$diskImage of=root_part bs=512 skip="''${OFFSETS[2]}" count="''${OFFSETS[3]}"

    # can be removed once android e2fsck supports this feature
    tune2fs -O ^orphan_file root_part
    fsck.fat -v -a efi_part

    cp ${vm_config} vm_config.json

    sed -i "s/{efi_part_guid}/$(sfdisk --part-uuid $diskImage 1)/g" vm_config.json
    sed -i "s/{root_part_guid}/$(sfdisk --part-uuid $diskImage 2)/g" vm_config.json

    contents=(
    build_id
    root_part
    efi_part
    vm_config.json
    )

    # payloadFiles are files vm_config.json refers to by name. Under Android 17
    # that is the kernel and initrd: the app hands both straight to crosvm and
    # never looks at the ESP, so the copies the installed bootloader made in
    # efi_part are never read.
    ${lib.concatMapStrings (f: ''
      cp ${lib.escapeShellArg f.src} ${lib.escapeShellArg f.name}
      contents+=(${lib.escapeShellArg f.name})
    '') payloadFiles}

    ${lib.concatMapStrings (name: ''
      cp ${lib.escapeShellArg "${extraFiles.${name}}"} ${lib.escapeShellArg name}
      contents+=(${lib.escapeShellArg name})
    '') (lib.attrNames extraFiles)}

    # --sparse option isn't supported in apache-commons-compress
    tar cv -I pigz -f $out -C . "''${contents[@]}"
  '';
}
