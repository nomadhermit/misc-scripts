# misc-scripts

Beachcam-capture.sh - get list of "public" live Portugal beachcams and captures some frames to a folder 

Beachcam-capturev2.sh - get list of "public" live Portugal beachcams and captures some frames to a folder as default or option to record video for specified duration as well as filter beachcams based on string
```
Options:
  -v [seconds]   Capture video (default: 20 seconds)
  -i [frames]    Capture frames (default: 4 frames)
  -f <text>      Filter beachcams by name (case-insensitive)
  -h             Show this help
```
Examples use cases:
```
# run through list of beachcams saving one frame from each, wait 15 minutes and repeat. do this 6 times.
for i in {1..6}; do ./beachcam-capturev2.sh -i 1; sleep 900; done

# wait two hours then run through list of beachcams saving one frame from each, wait 10 minutes and repeat (8 times)
sleep 2h; for i in {1..8}; do ./beachcam-capturev2.sh -i 1; sleep 300; done

# capture 30 seconds of video from any beachcam in list with name containing "capari" 
./beachcam-capturev2.sh -v 30 -f capari
```
note: usefule for remote viewing of captured frames/vids if script run on headless system - 
 (now archived) https://github.com/filebrowser/filebrowser
https://github.com/gtsteffaniak/filebrowser


