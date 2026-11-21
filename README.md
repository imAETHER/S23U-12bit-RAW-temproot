Unlocks some camera features via memory patching and hooking, temp root friendly!

<hr>

**Tested on:**
|Device (build number) | Status|
|----|----|
| **S918B**XXSAFZI1 | ✅ Working 12-bit, 60fps main, iDCG and DSG |
| S23 (base) / S23+ | ❌ Different main sensor, ultrawide untested |

If you've tried it on your S23 device, [create an issue](https://github.com/imAETHER/S23U-12bit-RAW-temproot/issues/new?template=general_report.yml) to let me know how it went! I'd like to support all the S23 versions.

## Setup:
Download both [`mc_repatch.sh`](https://github.com/imAETHER/S23U-12bit-RAW-temproot/blob/main/mc_repatch.sh) and [`cs_final.js`](https://github.com/imAETHER/S23U-12bit-RAW-temproot/blob/main/cs_final.js) from this repo.

Run on Termux as **non-root**:
1. `pkg install xz-utils`
2. `curl -LO https://github.com/frida/frida/releases/download/17.27.0/frida-inject-17.27.0-android-arm64.xz`
3. `unxz frida-inject-17.27.0-android-arm64.xz`

You should end up with a binary `frida-inject-17.27.0-android-arm64` in the current dir.

Switch to root:
1. `su`
2. `mv /data/data/com.termux/files/home/frida-inject-17.27.0-android-arm64 /data/local/tmp/frida-inject`
3. `chmod +x /data/local/tmp/frida-inject` <- makes it executable
4. `cd /sdcard/Download` (or wherever you put the files, keep the .sh and .js together)
5. `sh mc_repatch.sh`

Keep the script running! you can use `termux-wake-lock` and click the notification's "Acquire wakelock" to prevent it from being killed.

> [!IMPORTANT]
> **If you're using MotionCam, read this:**
<details>
  <summary>MotionCam guide</summary>
  <hr>
  → On first open you'll probably get a camera error. Hit "Cancel" on the retry prompt, go to "Settings" and set both lenses `0/2 14mm` and `0/5 23mm` from RAW10 to RAW_SENSOR. The 12bit frames don't fit in the 10 buffer, so the provider crashes until you change it.
  
  If it keeps duplicating those entries with RAW10 or wrong resolution (not `4000x3000`), its probably because of a saved lens profile, export your current ones and hit "RESET", then you can do the above.
  
  `(i)` Switching from the 14mm to the main 23mm tends to show the "Retrying" message. Let it retry once or twice.
  If it keeps failing, cancel and re-check the settings, they sometimes reset to RAW10 when the patch applied late.

  *Optional*: **60 fps** is only on the main camera, available using the "Advanced -> Show other framerates" option, expect CPU throttled warning and possibly dropped frames; active cooling is recommended.
  
  » That's it! enjoy

  *Seeing anomalies like mirroring or green lines at the edges? read the MotionCam user manual, page 83*
  <hr>
</details>

Otherwise, everything should be up and working!
I haven't tested this with other RAW camera apps so let me know if it works in others by [creating an issue](https://github.com/imAETHER/S23U-12bit-RAW-temproot/issues/new?template=general_report.yml)

## Stopping it:
Do <kbd>Ctrl</kbd>+<kbd>C</kbd> then run this command (as root):\
`pkill -f mc_repatch.sh; pkill -f camera.provider; killall cameraserver`\
(or soft reboot). Killing only the script leaves cameraserver patched and the provider unpatched, can cause issues like provider crashes due to buffer size mismatch.

