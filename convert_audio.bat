@echo off
rem Converts the Balatro sounds (ogg) into Wii-friendly WAV files.
rem Needs ffmpeg (type "ffmpeg -version" in a normal command window to check).
rem Usage: put this file next to the folder "resources" of your Balatro copy
rem        (the folder that contains resources\sounds) and double click it.
rem Result: a new folder "audio" with the converted files.

if not exist "resources\sounds" (
  echo Cannot find resources\sounds here. Move this file next to the resources folder.
  pause
  exit /b 1
)
if not exist "audio" mkdir "audio"

for %%F in ("resources\sounds\*.ogg") do (
  echo %%~nF | findstr /b /i "music" >nul
  if not errorlevel 1 (
    ffmpeg -y -loglevel error -i "%%F" -ac 2 -ar 32000 -c:a pcm_s16le "audio\%%~nF.wav"
  ) else (
    ffmpeg -y -loglevel error -i "%%F" -ac 1 -ar 32000 -c:a pcm_s16le "audio\%%~nF.wav"
  )
)
echo Done. Now move the "audio" folder to "your sd card":\balatro\src.
pause