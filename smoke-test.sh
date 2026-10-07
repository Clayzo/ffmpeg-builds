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

# Sound. clayzo decodes each audio file a document uses to raw samples, mixes
# them, and encodes the mix beside the picture: AAC in mp4, Opus in webm, PCM
# in mov. A WAV of noise as long as the frames stands in for the file.
rate=48000
samples=$((rate * frames / 30))
le16() { printf "$(printf '\\x%02x\\x%02x' $(($1 & 255)) $(($1 >> 8 & 255)))"; }
le32() { printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)))"; }
data_bytes=$((samples * 2 * 2))
{
  printf 'RIFF'; le32 $((36 + data_bytes)); printf 'WAVEfmt '
  le32 16; le16 1; le16 2; le32 $rate; le32 $((rate * 4)); le16 4; le16 16
  printf 'data'; le32 $data_bytes
  head -c $data_bytes /dev/urandom
} > "$work/sound.wav"

# The way clayzo reads a document's audio file.
ff -i "$work/sound.wav" -f f32le -ac 2 -ar $rate "$work/sound.f32"
bytes=$(wc -c < "$work/sound.f32" | tr -d ' ')
if [ "$bytes" -ne $((samples * 2 * 4)) ]; then
  echo "sound.wav decoded to $bytes bytes, expected $((samples * 2 * 4))" >&2
  exit 1
fi
echo "sound.wav: $samples samples decoded"

# The arguments media/node.ts passes when an export carries sound.
for pair in "mp4 -c:a aac -b:a 192k" "webm -c:a libopus -b:a 160k" "mov -c:a pcm_s24le"; do
  set -- $pair
  ext=$1
  shift
  video=()
  case $ext in
    mp4) video=(-c:v libx264 -crf 8 -pix_fmt yuv420p -movflags +faststart) ;;
    webm) video=(-c:v libvpx-vp9 -crf 9 -b:v 0 -pix_fmt yuva420p -auto-alt-ref 0) ;;
    mov) video=(-c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le) ;;
  esac
  encode "sound.$ext" -f f32le -ar $rate -ac 2 -i "$work/sound.f32" -map 0:v:0 -map 1:a:0 "${video[@]}" "$@"
  decoder=()
  [ "$ext" = webm ] && decoder=(-c:v libvpx-vp9)
  ff ${decoder[@]+"${decoder[@]}"} -i "$work/sound.$ext" -map 0:v:0 -f rawvideo -pix_fmt rgba -fps_mode passthrough "$work/sound.$ext.rgba"
  bytes=$(wc -c < "$work/sound.$ext.rgba" | tr -d ' ')
  if [ "$bytes" -ne $((frame_bytes * frames)) ]; then
    echo "sound.$ext decoded to $bytes bytes of picture, expected $((frame_bytes * frames))" >&2
    exit 1
  fi
  ff -i "$work/sound.$ext" -map 0:a:0 -f f32le -ac 2 -ar $rate "$work/sound.$ext.f32"
  bytes=$(wc -c < "$work/sound.$ext.f32" | tr -d ' ')
  # Lossy codecs pad to whole packets; within a packet of the original either way.
  if [ "$bytes" -lt $(((samples - 2048) * 8)) ] || [ "$bytes" -gt $(((samples + 2048) * 8)) ]; then
    echo "sound.$ext decoded to $((bytes / 8)) samples of sound, expected about $samples" >&2
    exit 1
  fi
  if cmp -s -n "$bytes" "$work/sound.$ext.f32" /dev/zero; then
    echo "sound.$ext decoded to silence" >&2
    exit 1
  fi
  echo "sound.$ext: $frames frames and $((bytes / 8)) samples of sound round-trip"
done
