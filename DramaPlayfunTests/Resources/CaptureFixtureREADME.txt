Synthetic test fixture for PlaybackCaptureTests.
No production media or secrets. AES key and IV are the test bytes 00 through 0f.
160x288 H.264 baseline at 12 fps with a 440 Hz AAC tone, 6 seconds, three 2-second MPEG-TS segments.
Segments are bundled with .bin suffixes so Xcode copies them as resources; the loopback server serves them at the .ts URLs in the manifest.

Generated with ffmpeg:
ffmpeg -f lavfi -i testsrc2=size=160x288:rate=12 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 6 -c:v libx264 -preset veryfast -profile:v baseline -pix_fmt yuv420p -b:v 100k -g 24 -keyint_min 24 -sc_threshold 0 -c:a aac -b:a 32k -ac 1 -f hls -hls_time 2 -hls_playlist_type vod -hls_key_info_file key-info.txt -hls_segment_filename EncryptedCapture%d.bin EncryptedCapture.m3u8

key-info.txt (generation-only; not needed at runtime):
CaptureTestKey.bin
<absolute path to CaptureTestKey.bin>
000102030405060708090a0b0c0d0e0f

SeparateCapture.m3u8 is a synthetic multivariant HLS fixture with independent
fragmented MP4 video, M4A audio and WebVTT subtitle renditions. Its media playlists
use EXT-X-MAP and byte ranges in single files, matching the production transport
shape that the MPEG-TS fixture does not exercise. It has no encryption or secrets.
The color test pattern lets the regression verify actual nonblack decoded pixels.

Generated in this directory with ffmpeg:
ffmpeg -f lavfi -i testsrc2=size=160x288:rate=12 -t 6 -an -c:v libx264 -preset veryfast -profile:v baseline -pix_fmt yuv420p -b:v 100k -g 24 -keyint_min 24 -sc_threshold 0 -f hls -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 -hls_flags single_file -hls_segment_filename SeparateCaptureVideo.mp4 SeparateCaptureVideo.m3u8
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=44100 -t 6 -vn -c:a aac -b:a 32k -ac 1 -f hls -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 -hls_flags single_file -hls_segment_filename SeparateCaptureAudio.m4a SeparateCaptureAudio.m3u8
