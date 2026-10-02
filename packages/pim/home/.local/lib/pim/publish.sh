#!/usr/bin/env bash
# pim library: publishing a build as one standalone file. Sourced by ~/.local/bin/pim; functions only.

# `pim publish [-c] [-o path] [--arch A] <image>`: flatten the build (and any from: chain under
# it) into a single qcow2, optionally compressed, plus its UEFI vars for arm64
cmd_publish() {
  local compress=false out="" arch="" spec=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--compress) compress=true ;;
      -o) out="${2:?-o needs a path}"; shift ;;
      --arch) arch="${2:?--arch needs a value}"; shift ;;
      -*) die "publish: unknown option '$1'" ;;
      *) spec="$1" ;;
    esac
    shift
  done
  [[ -n "$spec" ]] || die "Usage: pim publish [-c] [-o path] [--arch A] <image>"
  local id name disk key
  id=$(canon_or_die "$spec")
  name=$(img_name "$id")
  arch=$(img_pick_arch "$id" "$arch")
  [[ "$(img_backend "$id")" == qemu ]] || die "publish writes qcow2; $id is a $(img_backend "$id") image"
  disk=$(build_disk "$name" "$arch") || die "$id has no $arch build (pim build $id)"
  key=$(meta_get "$name" "$arch" .cache_key)
  [[ -n "$out" ]] || out="$PIM_DATA_HOME/published/$name-$arch-$key.qcow2"
  mkdir -p "$(dirname "$out")"
  echo "Writing $(tilde "$out")$($compress && echo " (compressed)")"
  if $compress; then qemu-img convert -c -O qcow2 "$disk" "$out"
  else qemu-img convert -O qcow2 "$disk" "$out"
  fi
  [[ -f "${disk%.qcow2}-efivars.fd" ]] && cp "${disk%.qcow2}-efivars.fd" "${out%.qcow2}-efivars.fd"
  OUT="$out" AT="$(now_iso)" C="$compress" yq -i \
    '.published += [{"path": strenv(OUT), "at": strenv(AT), "compressed": (strenv(C) == "true")}]' "$(meta_file "$name" "$arch")"
  echo "Published $id ($arch): $(tilde "$out") ($(file_size "$out"))"
}
