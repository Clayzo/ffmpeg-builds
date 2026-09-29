// Writes one npm package per target into npm/dist/<target>/.
//
//   node npm/package.mjs <version> <builds-directory>
//
// <builds-directory>/<target>/ holds a build: ffmpeg (ffmpeg.exe on
// Windows), COPYING.GPLv2 and VERSIONS, as build.sh leaves them.
import { chmodSync, copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [version, builds] = process.argv.slice(2);
if (!/^\d+\.\d+\.\d+$/.test(version ?? "") || builds === undefined) {
  throw new Error("usage: node npm/package.mjs <version> <builds-directory>");
}
const repository = "https://github.com/Clayzo/ffmpeg-builds";
const dist = join(dirname(fileURLToPath(import.meta.url)), "dist");
const targets = {
  "darwin-arm64": { os: "darwin", cpu: "arm64", label: "macOS on Apple Silicon" },
  "darwin-x64": { os: "darwin", cpu: "x64", label: "macOS on Intel" },
  "linux-x64": { os: "linux", cpu: "x64", label: "Linux on x64 (static, any libc)" },
  "linux-arm64": { os: "linux", cpu: "arm64", label: "Linux on arm64 (static, any libc)" },
  "win32-x64": { os: "win32", cpu: "x64", label: "Windows on x64" },
};

rmSync(dist, { recursive: true, force: true });
for (const [target, { os, cpu, label }] of Object.entries(targets)) {
  const from = join(builds, target);
  const to = join(dist, target);
  const executable = os === "win32" ? "ffmpeg.exe" : "ffmpeg";
  const versions = Object.fromEntries(
    readFileSync(join(from, "VERSIONS"), "utf8").trim().split("\n").map((line) => line.split(" ")),
  );
  mkdirSync(to, { recursive: true });
  copyFileSync(join(from, executable), join(to, executable));
  chmodSync(join(to, executable), 0o755);
  copyFileSync(join(from, "COPYING.GPLv2"), join(to, "LICENSE"));
  const name = `@clayzo/ffmpeg-${target}`;
  const manifest = {
    name,
    version,
    description: `FFmpeg ${versions.ffmpeg} for ${label}, built for the clayzo CLI`,
    license: "GPL-2.0-or-later",
    repository: { type: "git", url: `git+${repository}.git` },
    homepage: repository,
    os: [os],
    cpu: [cpu],
    files: [executable, "LICENSE", "README.md"],
    // Yarn's Plug'n'Play keeps packages zipped; a binary has to be on disk.
    preferUnplugged: true,
  };
  writeFileSync(join(to, "package.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  writeFileSync(
    join(to, "README.md"),
    `# ${name}

FFmpeg ${versions.ffmpeg} for ${label}, built for the [clayzo](https://www.npmjs.com/package/clayzo) CLI. clayzo installs it on this platform itself; you don't need to install it.

It holds only what clayzo's exports use: x264 for H.264, libvpx for VP9 with alpha, ProRes 4444, GIF and libwebp for animated WebP with alpha, and the decoders that verify them. No network access, devices or system libraries beyond the operating system's own.

| Component | Version | License |
| --- | --- | --- |
| FFmpeg | ${versions.ffmpeg} | GPL-2.0-or-later as built (LGPL-2.1-or-later without x264) |
| x264 | ${versions.x264} | GPL-2.0-or-later |
| libvpx | ${versions.libvpx} | BSD-3-Clause |
| libwebp | ${versions.libwebp} | BSD-3-Clause |

## License and source

This binary is licensed under the GNU General Public License, version 2 or (at your option) any later version; see \`LICENSE\`. Its complete corresponding source, the FFmpeg, x264, libvpx and libwebp sources and the scripts that built it, is published with the release it came from: ${repository}/releases/tag/v${version}.
`,
  );
  console.log(`${name}@${version}`);
}
