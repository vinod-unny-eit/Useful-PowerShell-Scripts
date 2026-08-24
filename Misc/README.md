# PowerShell Scripts for misc work

## Convert-VideoToMKV.ps1
Converts video files to H.265 MKV files using FFMPG. Requires FFMEG on disk and path updated in script. Multiple options for single or multiple files to file or folders. 

## Extract-VideoClipFromFile.ps1
Extracts a clip from a video file using the start and end time provided. The output is also converted to H.265 MKV in the destination path or file specified.

## Download-VideoFromWeb.ps1
Downloads a video from a URL using YT-DLP. You can optionally also specify only a clip to download. Lets you select the audio and video streams you wish to download and converts the output to H.265 MKV in the destination path or file specified.