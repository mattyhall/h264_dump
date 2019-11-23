# h264_dump
Dump the NAL units of a .264 file. Should have a similar output to the ffmpeg command:

```
ffmpeg -i <file> -c copy -bsf:v trace_headers -f null - 2>&1
```
