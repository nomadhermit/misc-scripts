#!/bin/bash

#  hack collection of  commands to get an end result... optimization and cleanup pending

# make dimansions consistent
mkdir output
for i in *.jpg; do      time=$(echo $i | cut -d . -f 1);     ffmpeg -nostdin -y -i $i -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=black" ./output/$time.jpg; done

cd output
# embed filename in image (removing '_001' from name)
mkdir raw
for i in *.jpg; do      time=$(echo $i | cut -d . -f 1 | rev | cut -c 5- | rev )'(EST)';     ffmpeg -nostdin -y -i $i -vf "drawtext=text=$time:fontsize=32:fontcolor=yellow:x=10:y=10" ./raw/mod-$time.jpg; done

cd raw
# create souce file list for ffmpeg
ls  mod*.jpg | cat -n | while read n f; do echo "file '$f'"; done > list.txt

# generate video from files
ffmpeg -nostdin -f concat -safe 0 -i list.txt -vf "setpts=3*PTS" -c:v libx264 -pix_fmt yuv420p timelapse.mp4


