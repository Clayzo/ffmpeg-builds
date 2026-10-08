#!/usr/bin/env bash
# Builds the ffmpeg the clayzo CLI ships, from pinned sources, for one target.
#
#   build.sh <target> <work-directory>
#
#   darwin-arm64, darwin-x64   on macOS (either architecture)
#   linux-x64, linux-arm64     on Alpine Linux of that architecture (static, musl)
#   win32-x64                  on Linux with mingw-w64
#
# The binary lands in <work-directory>/out/<target>/.
#
# It holds what an export uses and nothing else: x264 for mp4, libvpx VP9 with
# alpha for webm, ProRes 4444 for mov, GIF, libwebp for animated WebP with
# alpha, the decoders that verify each, and raw frames in over a pipe. For
# sound: the decoders for the audio files a document uses, FFmpeg's AAC for
# mp4, libopus for webm, PCM for mov, and raw samples in and out. No network,
# devices or autodetected system libraries. GPL because of x264, never nonfree,
# so it can be redistributed.
set -euo pipefail

target=${1:?target}
work=$(mkdir -p "${2:?work directory}" && cd "$2" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)
# Shared between targets when set, so each source is fetched once.
downloads=${FFMPEG_DOWNLOADS:-$work/downloads}
build=$work/build/$target
prefix=$build/prefix
out=$work/out/$target
mkdir -p "$downloads" "$build" "$prefix/bin" "$out"

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Downloads (once) and unpacks a pinned source, refusing one whose checksum
# does not match sources.txt. A fallback URL there is tried when the first
# serves anything else.
source_dir() {
  local name=$1 url sum fallback file
  read -r _ _ url sum fallback < <(grep "^$name " "$here/sources.txt")
  file=$downloads/$(basename "$url")
  [ -f "$file" ] || curl -fsSL --retry 3 -o "$file" "$url" || true
  if [ "$(sha256 "$file" 2>/dev/null)" != "$sum" ] && [ -n "$fallback" ]; then
    curl -fsSL --retry 3 -o "$file" "$fallback"
  fi
  if [ "$(sha256 "$file")" != "$sum" ]; then
    echo "$file does not match its pinned sha256" >&2
    exit 1
  fi
  local dir=$build/src/$name
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    tar -xf "$file" -C "$dir" --strip-components=1
  fi
  echo "$dir"
}

case $target in
  darwin-arm64 | darwin-x64)
    arch=${target#darwin-}
    [ "$arch" = x64 ] && arch=x86_64
    export MACOSX_DEPLOYMENT_TARGET=11.0
    cc="clang -arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
    x264_host=$([ "$arch" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
    vpx_target=$([ "$arch" = arm64 ] && echo arm64-darwin20-gcc || echo x86_64-darwin20-gcc)
    ff_target=(--target-os=darwin --arch="$arch" --enable-cross-compile --cc="$cc")
    ldflags=""
    extra_libs=""
    ;;
  linux-x64 | linux-arm64)
    arch=$([ "$target" = linux-x64 ] && echo x86_64 || echo aarch64)
    [ "$(uname -m)" = "$arch" ] || { echo "$target builds natively on $arch" >&2; exit 1; }
    cc=gcc
    x264_host=$arch-linux-musl
    vpx_target=$([ "$arch" = x86_64 ] && echo x86_64-linux-gcc || echo arm64-linux-gcc)
    ff_target=(--cc=gcc)
    ldflags="-static"
    extra_libs=""
    ;;
  win32-x64)
    arch=x86_64
    cross=x86_64-w64-mingw32-
    cc=${cross}gcc
    x264_host=x86_64-w64-mingw32
    vpx_target=x86_64-win64-gcc
    ff_target=(--target-os=mingw32 --arch=x86_64 --enable-cross-compile --cross-prefix="$cross")
    ldflags="-static -static-libgcc"
    # mingw keeps the stack protector's runtime in libssp.
    extra_libs="-lssp"
    ;;
  *)
    echo "unknown target $target" >&2
    exit 1
    ;;
esac

# x86 SIMD is assembled with nasm (built below); these are empty elsewhere.
vpx_asm=()
ff_asm=()
if [ "$arch" = x86_64 ]; then
  vpx_asm=(--as=nasm)
  ff_asm=(--x86asmexe=nasm)
fi

export PKG_CONFIG_PATH=$prefix/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig
export PATH=$prefix/bin:$PATH

# nasm assembles x264's, libvpx's and FFmpeg's x86 SIMD; built here rather
# than taken from the host so every x86 build uses the same one.
if [ "$arch" = x86_64 ] && [ ! -x "$prefix/bin/nasm" ]; then
  src=$(source_dir nasm)
  (cd "$src" && CC=${HOST_CC:-cc} ./configure --prefix="$prefix" >/dev/null && make -j"$jobs" nasm >/dev/null && install -m 755 nasm "$prefix/bin/nasm")
fi

if [ ! -f "$prefix/lib/libx264.a" ]; then
  src=$(source_dir x264)
  (
    cd "$src"
    # 8-bit 4:2:0 is all an export encodes; the other depths and chroma formats
    # only add size.
    if [ "$arch" = x86_64 ]; then export AS=nasm; else unset AS; fi
    CC="$cc" ./configure \
      --prefix="$prefix" --host="$x264_host" ${cross:+--cross-prefix="$cross"} \
      --enable-static --enable-pic --disable-cli --disable-opencl \
      --disable-avs --disable-swscale --disable-lavf --disable-ffms --disable-gpac --disable-lsmash \
      --bit-depth=8 --chroma-format=420
    make -j"$jobs"
    make install-lib-static
  )
fi

if [ ! -f "$prefix/lib/libvpx.a" ]; then
  src=$(source_dir libvpx)
  (
    cd "$src"
    # VP9 only: the encoder for webm, and the decoder that reads its alpha back
    # when an export is verified.
    CC="$cc" CROSS=${cross:-} ./configure \
      --prefix="$prefix" --target="$vpx_target" \
      --enable-static --disable-shared --enable-pic \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests \
      --disable-vp8 --enable-vp9 --disable-webm-io --disable-libyuv \
      ${vpx_asm[@]+"${vpx_asm[@]}"}
    make -j"$jobs"
    make install
  )
fi

if [ ! -f "$prefix/lib/libwebp.a" ]; then
  src=$(source_dir libwebp)
  (
    cd "$src"
    # The encoder and the animation muxer (WebPAnimEncoder) FFmpeg's
    # libwebp_anim uses; FFmpeg decodes WebP itself when an export is verified.
    CC="$cc" ./configure \
      --prefix="$prefix" --host="$x264_host" \
      --enable-static --disable-shared --with-pic \
      --enable-libwebpmux --disable-libwebpdemux --disable-libwebpdecoder --disable-libwebpextras \
      --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic --disable-sdl --disable-gl
    make -j"$jobs"
    make install
  )
fi

if [ ! -f "$prefix/lib/libopus.a" ]; then
  src=$(source_dir opus)
  (
    cd "$src"
    # The encoder for webm's sound. FFmpeg's own Opus encoder is still
    # experimental; FFmpeg decodes Opus itself when an export is verified.
    CC="$cc" ./configure \
      --prefix="$prefix" --host="$x264_host" \
      --enable-static --disable-shared --with-pic \
      --disable-doc --disable-extra-programs
    make -j"$jobs"
    make install
  )
fi

src=$(source_dir ffmpeg)
(
  cd "$src"
  # Parsers are listed by hand: the gif demuxer needs its parser to split
  # frames, and configure does not select it. WebP needs both demuxers:
  # libwebp writes an animation whose frames are all the same as a still.
  #
  # Sound: clayzo decodes each audio file a document uses to raw samples
  # (f32le out), mixes them itself, and hands the mix back (f32le in) to be
  # encoded beside the picture. The demuxers and decoders cover the files a
  # document is likely to hold (WAV, AIFF, MP3, AAC and M4A, Ogg Vorbis and
  # Opus, FLAC, WebM); aresample and aformat are what FFmpeg inserts to
  # convert between them.
  ./configure \
    --prefix="$prefix" \
    "${ff_target[@]}" \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --extra-cflags="-I$prefix/include -fstack-protector-strong" \
    --extra-ldflags="-L$prefix/lib $ldflags" \
    ${extra_libs:+--extra-libs="$extra_libs"} \
    ${ff_asm[@]+"${ff_asm[@]}"} \
    --enable-gpl --enable-libx264 --enable-libvpx --enable-libwebp --enable-libopus \
    --disable-autodetect --disable-everything --disable-network \
    --disable-doc --disable-debug --disable-ffplay --disable-ffprobe --disable-avdevice \
    --enable-protocol=file,pipe \
    --enable-demuxer=rawvideo,mov,matroska,gif,webp_anim,image_webp_pipe \
    --enable-demuxer=wav,aiff,mp3,aac,ogg,flac,pcm_f32le \
    --enable-muxer=mp4,mov,webm,gif,webp,rawvideo,pcm_f32le \
    --enable-encoder=libx264,libvpx_vp9,prores_ks,gif,libwebp_anim,rawvideo \
    --enable-encoder=aac,libopus,pcm_s24le,pcm_f32le \
    --enable-decoder=rawvideo,h264,prores,libvpx_vp9,vp9,gif,webp_anim,webp \
    --enable-decoder=pcm_u8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be \
    --enable-decoder=pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_alaw,pcm_mulaw \
    --enable-decoder=mp3float,aac,alac,flac,vorbis,opus \
    --enable-parser=gif,h264,vp9,prores,webp,aac,mpegaudio,flac,vorbis,opus \
    --enable-bsf=vp9_superframe,vp9_superframe_split \
    --enable-filter=format,split,palettegen,paletteuse,scale,null,copy,fps,setpts,trim \
    --enable-filter=aresample,aformat,anull,atrim,asetpts
  make -j"$jobs"
)

exe=ffmpeg$([ "$target" = win32-x64 ] && echo .exe || true)
cp "$src/$exe" "$out/$exe"
case $target in
  darwin-*)
    strip "$out/$exe"
    # Stripping invalidates the linker's ad-hoc signature, without which
    # Apple Silicon refuses to run the binary.
    codesign --force --sign - "$out/$exe"
    ;;
  linux-*) strip "$out/$exe" ;;
  win32-*) "${cross}strip" "$out/$exe" ;;
esac
cp "$src/COPYING.GPLv2" "$out/COPYING.GPLv2"
awk '$1 == "ffmpeg" || $1 == "x264" || $1 == "libvpx" || $1 == "libwebp" || $1 == "opus" { print $1, $2 }' "$here/sources.txt" > "$out/VERSIONS"
echo "built $out/$exe ($(wc -c < "$out/$exe") bytes)"
