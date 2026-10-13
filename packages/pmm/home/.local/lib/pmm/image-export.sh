#!/usr/bin/env bash
# pmm library: exporting a build as one standalone file. Sourced by ~/.local/bin/pmm; functions only.

# `pmm image export [-c] [-o file] [--arch A] <image>`: flatten the build (and any from: chain under
# it) into a single qcow2, optionally compressed, plus its UEFI vars for arm64
cmd_image_export() {
  local compress=${CLI_OPT[compress]:-false} out="${CLI_OPT[output]:-}" arch="${CLI_OPT[arch]:-}"
  local id name disk key
  id=$(img_canon_or_die "$1")
  name=$(img_name "$id")
  arch=$(img_pick_arch "$id" "$arch")
  [[ "$(img_backend "$id")" == qemu ]] || die "export writes qcow2; $id is a $(img_backend "$id") image"
  disk=$(build_disk "$name" "$arch") || die "$id has no $arch build (pmm image build $id)"
  key=$(meta_get "$name" "$arch" .cache_key)
  [[ -n "$out" ]] || out="$PMM_DATA_HOME/exports/$name-$arch-$key.qcow2"
  mkdir -p "$(dirname "$out")"
  echo "Writing $(tilde "$out")$($compress && echo " (compressed)")"
  if $compress; then qemu-img convert -c -O qcow2 "$disk" "$out"
  else qemu-img convert -O qcow2 "$disk" "$out"
  fi
  [[ -f "${disk%.qcow2}-efivars.fd" ]] && cp "${disk%.qcow2}-efivars.fd" "${out%.qcow2}-efivars.fd"
  OUT="$out" AT="$(now_iso)" C="$compress" yq -i \
    '.exports += [{"path": strenv(OUT), "at": strenv(AT), "compressed": (strenv(C) == "true")}]' "$(meta_file "$name" "$arch")"
  echo "Exported $id ($arch): $(tilde "$out") ($(file_size "$out"))"
}
