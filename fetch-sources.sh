#!/usr/bin/env bash
# Downloads every pinned source into <directory> and checks it: each file
# against its sha256 in sources.txt, and FFmpeg's tarball against FFmpeg's
# release signature, made with the key in keys/ and pinned by fingerprint.
#
#   fetch-sources.sh <directory>
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
dir=$(mkdir -p "${1:?directory}" && cd "$1" && pwd)
ffmpeg_key=FCF986EA15E6E293A5644F10B4322F04D67658D8

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

grep -v '^#' "$here/sources.txt" | while read -r name version url sum; do
  [ -n "$name" ] || continue
  file=$dir/$(basename "$url")
  [ -f "$file" ] || curl -fsSL --retry 3 -o "$file" "$url"
  if [ "$(sha256 "$file")" != "$sum" ]; then
    echo "$file does not match its pinned sha256" >&2
    exit 1
  fi
  if [ "$name" = ffmpeg ]; then
    [ -f "$file.asc" ] || curl -fsSL --retry 3 -o "$file.asc" "$url.asc"
    home=$(mktemp -d)
    gpg --homedir "$home" --batch --quiet --import "$here/keys/ffmpeg-release.asc"
    if ! gpg --homedir "$home" --batch --status-fd 1 --verify "$file.asc" "$file" 2>/dev/null |
      grep -q "^\[GNUPG:\] VALIDSIG $ffmpeg_key "; then
      echo "$file is not signed by FFmpeg's release key" >&2
      exit 1
    fi
    rm -rf "$home"
  fi
  echo "$name $version: verified"
done
