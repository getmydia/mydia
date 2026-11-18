#!/usr/bin/env bash
# Generate calibrated HDR test clips for judging HDR output by eye and by probes.
#
#   scripts/generate-hdr-fixtures.sh <outdir>
#
# Writes levels_hdr10.mp4, levels_hlg.mp4, levels_dv81.mp4 and sdr_testsrc.mp4.
# The HDR10 and Dolby Vision clips carry three flat luma patches at 203, 1000
# and 4000 nits (10-bit limited luma 573, 722, 855) over a testsrc2 picture whose
# SDR white sits at 203 nits. HLG has no absolute nits, so it has no patches.
# The clips are generated, never committed (test/fixtures/hdr/ is ignored).
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <outdir>" >&2
  exit 2
fi

outdir=$1
mkdir -p "$outdir"
outdir=$(cd "$outdir" && pwd)

FRAMES=288 # 12 s at 24 fps

# Re-exec inside nix when a tool is missing. Homebrew's ffmpeg can lack zscale
# or libx265, so check the filters and encoders, not just the binary.
have_tools() {
  command -v ffmpeg >/dev/null &&
    command -v dovi_tool >/dev/null &&
    ffmpeg -nostdin -hide_banner -filters 2>/dev/null | grep -qw zscale &&
    ffmpeg -nostdin -hide_banner -encoders 2>/dev/null | grep -qw libx265 &&
    ffmpeg -nostdin -hide_banner -encoders 2>/dev/null | grep -qw libx264
}
if [ -z "${HDRFX_IN_NIX:-}" ] && ! have_tools; then
  exec env HDRFX_IN_NIX=1 nix shell nixpkgs#dovi-tool nixpkgs#ffmpeg-full \
    --command bash "$0" "$outdir"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# -nostdin: ffmpeg would otherwise swallow the rest of a script piped over ssh.
ff() { ffmpeg -nostdin -hide_banner -loglevel error -y "$@"; }

# testsrc2 (bt709) converted to a PQ or HLG bt2020 10-bit limited-range picture.
src() {
  echo "testsrc2=s=1920x1080:r=24:d=12,format=gbrpf32le,zscale=tin=bt709:pin=bt709:min=gbr:rin=full:t=$1:p=bt2020:m=bt2020nc:r=tv:npl=203,format=yuv420p10le"
}

# 400x300 patches at y 140; luma 573 / 722 / 855 = 203 / 1000 / 4000 nits.
# geq's X and Y are in the plane being filtered, so they are scaled back to
# luma coordinates (SW and SH are 1 for luma, 0.5 for 4:2:0 chroma): the
# chroma mask must neutralize exactly the luma patches.
patch() { echo "between(X/SW,$1,$2)*between(Y/SH,140,440)"; }
PATCHES="geq=lum='if($(patch 240 640),573,if($(patch 760 1160),722,if($(patch 1280 1680),855,lum(X,Y))))':cb='if($(patch 240 640)+$(patch 760 1160)+$(patch 1280 1680),512,cb(X,Y))':cr='if($(patch 240 640)+$(patch 760 1160)+$(patch 1280 1680),512,cr(X,Y))'"

COMMON=(-c:v libx265 -preset fast -crf 16 -pix_fmt yuv420p10le -color_primaries bt2020 -colorspace bt2020nc -tag:v hvc1)

# HDR10 levels. MaxCLL is the 4000-nit patch; MaxFALL is 0, "unknown": the
# patches alone put the frame average near 300 nits, and nothing here
# measures it.
ff -f lavfi -i "$(src smpte2084),$PATCHES" "${COMMON[@]}" -color_trc smpte2084 \
  -x265-params "hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(40000000,1):max-cll=4000,0:log-level=error" \
  "$outdir/levels_hdr10.mp4"

# HLG, no patches
ff -f lavfi -i "$(src arib-std-b67)" "${COMMON[@]}" -color_trc arib-std-b67 \
  -x265-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:log-level=error" \
  "$outdir/levels_hlg.mp4"

# Dolby Vision 8.1: inject a generated RPU into the HDR10 stream. Its peaks
# match the HDR10 base: 4000-nit mastering and MaxCLL, MaxFALL unknown, and
# an L1 max of 3697, the 12-bit PQ code for 4000 nits.
ff -i "$outdir/levels_hdr10.mp4" -c:v copy -bsf:v hevc_mp4toannexb -f hevc "$work/base.hevc"
cat >"$work/cfg.json" <<JSON
{"cm_version":"V40","profile":"8.1","length":$FRAMES,
 "level6":{"max_display_mastering_luminance":4000,"min_display_mastering_luminance":1,"max_content_light_level":4000,"max_frame_average_light_level":0},
 "default_metadata_blocks":[{"Level1":{"min_pq":0,"max_pq":3697,"avg_pq":2000}}]}
JSON
dovi_tool generate -j "$work/cfg.json" -o "$work/rpu.bin" >/dev/null
dovi_tool inject-rpu -i "$work/base.hevc" --rpu-in "$work/rpu.bin" -o "$work/dv.hevc" >/dev/null
ff -r 24 -i "$work/dv.hevc" -c copy -strict unofficial -tag:v dvh1 "$outdir/levels_dv81.mp4"

# SDR reference
ff -f lavfi -i "testsrc2=s=1920x1080:r=24:d=12,format=yuv420p" \
  -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  "$outdir/sdr_testsrc.mp4"

echo "wrote HDR fixtures to $outdir"
