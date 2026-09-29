# ffmpeg-builds

The FFmpeg that the [clayzo](https://www.npmjs.com/package/clayzo) CLI exports video with, built from source for five platforms and published to npm as one package per platform:

| Package | Platform |
| --- | --- |
| `@clayzo/ffmpeg-darwin-arm64` | macOS on Apple Silicon (11 and later) |
| `@clayzo/ffmpeg-darwin-x64` | macOS on Intel (11 and later) |
| `@clayzo/ffmpeg-linux-x64` | Linux on x64, fully static (any distribution, glibc or musl) |
| `@clayzo/ffmpeg-linux-arm64` | Linux on arm64, fully static |
| `@clayzo/ffmpeg-win32-x64` | Windows on x64 |

clayzo lists all five as optional dependencies, and the package manager installs only the one that matches the machine. Nothing runs at install time and nothing is downloaded outside the package manager.

## What is in the binary

Only what clayzo's exports use:

- FFmpeg with the `ffmpeg` command-line tool; no `ffprobe`, `ffplay`, devices or network protocols
- x264 for H.264 (mp4), libvpx for VP9 with alpha (webm), libwebp for animated WebP with alpha, FFmpeg's own ProRes 4444 (mov) and GIF encoders
- the decoders, demuxers and parsers that read those files back, which is how clayzo verifies an export
- raw frames in over a pipe, files and pipes out

System libraries are not autodetected. Each binary links only the operating system's own libraries, and on Linux none at all. It is about 7 to 11 MB, where a general-purpose static FFmpeg is 45 MB or more.

## Sources and verification

`sources.txt` pins every source by URL and sha256. `fetch-sources.sh` refuses a file whose checksum differs, and checks FFmpeg's tarball against FFmpeg's release signature, made with the key in `keys/` and pinned by fingerprint (`FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8`). When pinned, each source was also checked against Homebrew's formula: the same checksum for FFmpeg, libvpx and libwebp, and the same commit for x264.

The build container images are pinned by digest, and the workflow's actions by commit. Every build runs `smoke-test.sh`: each export format is encoded with clayzo's own arguments, decoded back and counted, and the license is checked to be redistributable. Windows builds are tested on Windows.

## Building

```sh
./fetch-sources.sh downloads
FFMPEG_DOWNLOADS=$PWD/downloads ./build.sh darwin-arm64 work   # on macOS; darwin-x64 cross-compiles
./smoke-test.sh work/out/darwin-arm64/ffmpeg
```

Linux and Windows build in the containers under `docker/`, as `.github/workflows/build.yml` shows.

## Releasing

Push a tag `vX.Y.Z`. The workflow builds and tests every target, creates a GitHub release with the five binaries, the exact FFmpeg, x264, libvpx and libwebp sources, and `SHA256SUMS`, then publishes the five npm packages at `X.Y.Z` with provenance. It needs an `NPM_TOKEN` secret that can publish to the `@clayzo` scope.

## License

The binaries are licensed under the GNU General Public License, version 2 or (at your option) any later version, because they include x264. FFmpeg is LGPL-2.1-or-later on its own, x264 is GPL-2.0-or-later, and libvpx and libwebp are BSD-3-Clause. The scripts in this repository are released under the same license, in `LICENSE`. Each GitHub release carries the complete corresponding source for its binaries.
