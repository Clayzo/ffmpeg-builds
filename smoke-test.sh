#!/usr/bin/env bash
# Runs a built ffmpeg through every export the clayzo CLI makes, with the
# CLI's own arguments, and decodes each result back the way the CLI verifies
# it. Needs nothing but the binary.
#
#   smoke-test.sh <path-to-ffmpeg> [runner, e.g. wine]
set -euo pipefail

ffmpeg=$1
runner=${2:-}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
width=64
height=48
frames=6
frame_bytes=$((width * height * 4))

ff() { $runner "$ffmpeg" -hide_banner -loglevel error "$@"; }

# Frames with real content: noise, including in the alpha channel.
head -c $((frame_bytes * frames)) /dev/urandom > "$work/frames.rgba"

# The license must be redistributable: GPL, never "nonfree".
license=$($runner "$ffmpeg" -hide_banner -L 2>&1)
if printf '%s' "$license" | grep -qi "not legally redistributable"; then
  echo "this build is nonfree" >&2
  exit 1
fi
printf '%s' "$license" | grep -q "GNU General Public License" || { echo "unexpected license: $license" >&2; exit 1; }

encode() {
  local name=$1
  shift
  ff -y -f rawvideo -pixel_format rgba -video_size ${width}x${height} -framerate 30 \
    -i "$work/frames.rgba" "$@" "$work/$name"
}

# The arguments media/node.ts passes for each format (quality 85).
encode out.mp4 -c:v libx264 -crf 8 -pix_fmt yuv420p -movflags +faststart
encode out.webm -c:v libvpx-vp9 -crf 9 -b:v 0 -pix_fmt yuva420p -auto-alt-ref 0
encode out.mov -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le
encode out.gif -filter_complex \
  "[0:v]format=rgb24,split[a][b];[a]palettegen=max_colors=222[p];[b][p]paletteuse=dither=bayer:bayer_scale=3" \
  -loop 0
encode out.webp -c:v libwebp_anim -lossless 0 -quality 85 -pix_fmt yuva420p -loop 0

for name in out.mp4 out.webm out.mov out.gif out.webp; do
  decoder=()
  [ "$name" = out.webm ] && decoder=(-c:v libvpx-vp9)
  ff ${decoder[@]+"${decoder[@]}"} -i "$work/$name" -map 0:v:0 -f rawvideo -pix_fmt rgba -fps_mode passthrough "$work/$name.rgba"
  bytes=$(wc -c < "$work/$name.rgba" | tr -d ' ')
  if [ "$bytes" -ne $((frame_bytes * frames)) ]; then
    echo "$name decoded to $bytes bytes, expected $((frame_bytes * frames)) ($frames frames)" >&2
    exit 1
  fi
  # The formats that keep transparency must still have it: the input's alpha
  # is noise, so most decoded pixels should be see-through.
  case $name in
    out.webm | out.mov | out.webp)
      see_through=$(od -An -v -tu1 "$work/$name.rgba" |
        awk '{ for (i = 1; i <= NF; i++) if (++k % 4 == 0 && $i < 255) n++ } END { print n + 0 }')
      if [ "$see_through" -lt $((width * height * frames / 2)) ]; then
        echo "$name lost its alpha: $see_through see-through pixels" >&2
        exit 1
      fi
      echo "$name: $frames frames round-trip, alpha kept"
      ;;
    *) echo "$name: $frames frames round-trip" ;;
  esac
done
