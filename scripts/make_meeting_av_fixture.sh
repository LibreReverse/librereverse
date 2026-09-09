#!/bin/zsh
set -euo pipefail

output_path="${1:-/private/tmp/librereverse-meeting-av-fixture.mp4}"
duration_seconds="${2:-60}"
frame_rate="${3:-30}"
font_path="/System/Library/Fonts/Helvetica.ttc"

if [[ -e "$output_path" ]]; then
  print -u2 "refusing to overwrite fixture: $output_path"
  exit 2
fi

# Every output frame carries its exact source index. Once per second the video
# flashes white for 50 ms while both audio channels emit a 1 kHz sync tone. The
# left channel otherwise carries 440 Hz and the right channel 660 Hz, allowing
# channel swaps, missing system audio, drift, and frame loss to be distinguished.
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=size=1920x1080:rate=${frame_rate}:duration=${duration_seconds}" \
  -f lavfi -i "aevalsrc=0.12*sin(2*PI*440*t)+0.45*sin(2*PI*1000*t)*lt(mod(t\,1)\,0.05)|0.12*sin(2*PI*660*t)+0.45*sin(2*PI*1000*t)*lt(mod(t\,1)\,0.05):s=48000:d=${duration_seconds}" \
  -vf "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t,1),0.05)',drawbox=x=40:y=40:w=950:h=160:color=black:t=fill,drawtext=fontfile=${font_path}:text='FRAME %{eif\\:n\\:d\\:8}':fontcolor=white:fontsize=96:x=70:y=65,drawtext=fontfile=${font_path}:text='FRAME %{n}  PTS %{pts\\:hms}':fontcolor=black:fontsize=72:box=1:boxcolor=white:boxborderw=20:x=(w-text_w)/2:y=h-text_h-120" \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -r "$frame_rate" \
  -c:a aac -b:a 192k -ar 48000 -ac 2 \
  -movflags +faststart -shortest "$output_path"

ffprobe -v error -show_entries \
  format=duration,size:stream=codec_type,codec_name,width,height,avg_frame_rate,sample_rate,channels,nb_frames \
  -of json "$output_path"
