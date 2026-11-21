"use strict";

// hooks into cameraserver, makes the main camera (HP2, 6.3mm) and ultrawide (2.2mm)
// report their 12bit RAW, white level 4095, black level 256, and the 4:3 size on the main camera.

const HOOKS = [
  {
    name: "getCameraCharacteristics",
    offset: 0x17a418,
    expected: "5f2403d5c20900b4",
  },
  {
    name: "getPhysicalCameraCharacteristics",
    offset: 0x17a5e0,
    expected: "3f2303d5fd7bbda9",
  },
  {
    name: "roundBufferDimensionNearest",
    offset: 0x308024,
    expected: "3f2303d5ff4302d1",
  },
];

const MAIN_FOCAL = 6.3;
const ULTRAWIDE_FOCAL = 2.2;

const RAW_FORMATS = new Set([0x20, 0x24, 0x25, 0x26]); // RAW_SENSOR, RAW_PRIVATE, RAW10, RAW12
const MAIN_RAW_FROM = [4080, 3060];
const MAIN_RAW_TO = [4000, 3000];

const TAG = {
  focalLengths: 0x00090002,
  blackLevel: 0x000e000c,
  whiteLevel: 0x000f0007,
  streamConfigs: [0x000d000a, 0x000d0014], // int32 [format, w, h, isInput]
  durations: [0x000d000b, 0x000d000c, 0x000d0015, 0x000d0016], // int64 [format, w, h, ns]
};

const TYPE_SIZE = [1, 4, 4, 8, 8, 8]; // byte, int32, float, int64, double, rational

// camera_metadata_t, from https://cs.android.com/android/platform/superproject/+/android-latest-release:system/media/camera/src/camera_metadata.c;l=94
function isMetadata(buf) {
  const size = buf.readU32();
  const entryCount = buf.add(0x0c).readU32();
  const entriesStart = buf.add(0x14).readU32();
  const dataStart = buf.add(0x20).readU32();

  return (
    size >= 0x40 &&
    size <= 0x200000 &&
    entryCount < 20000 &&
    entriesStart < size &&
    dataStart <= size
  );
}

// android::CameraMetadata -> camera_metadata_t* is at +8
function metadataOf(cameraMetadata) {
  const buf = cameraMetadata.add(8).readPointer();
  if (!buf.isNull() && isMetadata(buf)) return buf;

  return null;
}

function findEntry(buf, tag) {
  const count = buf.add(0x0c).readU32();
  const entries = buf.add(buf.add(0x14).readU32());

  for (let i = 0; i < count; i++) {
    const entry = entries.add(i * 16);
    if (entry.readU32() !== tag) continue;

    const n = entry.add(4).readU32();
    const bytes = n * TYPE_SIZE[entry.add(12).readU8()];

    const data =
      bytes <= 4
        ? entry.add(8)
        : buf.add(buf.add(0x20).readU32() + entry.add(8).readU32());

    return { count: n, data };
  }

  return null;
}

function isSameFocal(focal, target) {
  return Math.abs(focal - target) < 0.4;
}

// Rewrites (RAW format, 4080, 3060) rows. Stream configs are int32 rows of 4 values;
// durations are int64 rows of 4, so the same fields sit 8 bytes apart.
function rewriteRawSize(buf) {
  let changed = 0;
  const tables = TAG.streamConfigs
    .map((tag) => [tag, 4])
    .concat(TAG.durations.map((tag) => [tag, 8]));

  for (const [tag, width] of tables) {
    const entry = findEntry(buf, tag);
    if (!entry) continue;

    for (let row = 0; row < entry.count / 4; row++) {
      const format = entry.data.add(row * 4 * width);
      const w = format.add(width);
      const h = format.add(2 * width);

      if (
        RAW_FORMATS.has(format.readU32()) &&
        w.readU32() === MAIN_RAW_FROM[0] &&
        h.readU32() === MAIN_RAW_FROM[1]
      ) {
        w.writeU32(MAIN_RAW_TO[0]);
        h.writeU32(MAIN_RAW_TO[1]);

        changed++;
      }
    }
  }
  return changed;
}

// HAL would still report 10bit levels, so this fixes that
function writeLevels(buf) {
  const white = findEntry(buf, TAG.whiteLevel);
  if (white && white.data.readU32() === 1023) white.data.writeU32(4095);

  const black = findEntry(buf, TAG.blackLevel);
  if (black) {
    for (let i = 0; i < black.count; i++) {
      const level = black.data.add(i * 4);
      const value = level.readU32();

      if (value > 0 && value < 256) level.writeU32(256);
    }
  }
}

// going by focal length bc u can get that from all hooks, also cam0 has like several ids
function patchChars(camMeta, fixLevels) {
  try {
    const buf = metadataOf(camMeta);
    if (!buf) return;

    const entry = findEntry(buf, TAG.focalLengths);
    const focal = entry ? entry.data.readFloat() : 0;
    if (isSameFocal(focal, MAIN_FOCAL)) rewriteRawSize(buf);

    if (
      fixLevels &&
      (isSameFocal(focal, MAIN_FOCAL) || isSameFocal(focal, ULTRAWIDE_FOCAL))
    )
      writeLevels(buf);
  } catch (e) {} // just in case
}

function toHex(ptr, length) {
  return Array.from(new Uint8Array(ptr.readByteArray(length)), (b) =>
    b.toString(16).padStart(2, "0"),
  ).join("");
}

function setHook(name, callbacks) {
  const entry = HOOKS.find((h) => h.name === name);

  const target = Process.mainModule.base.add(entry.offset);
  const found = toHex(target, entry.expected.length / 2);

  if (found !== entry.expected) {
    console.log(
      `[cameraserver-hook] ${name}: expected ${entry.expected}, found ${found}. skipping!`,
    );
    return false;
  }

  Interceptor.attach(target, callbacks);
  return true;
}

const charsHook = {
  onEnter(args) {
    this.out = args[2];
  },
  onLeave() {
    patchChars(this.out, true);
  },
};

// u guys can add more hooks here if you'd like
const hooked = [
  setHook("getCameraCharacteristics", charsHook),
  setHook("getPhysicalCameraCharacteristics", charsHook),
  setHook("roundBufferDimensionNearest", {
    onEnter(args) {
      const format = args[2].toInt32();
      const info = args[4];
      if (RAW_FORMATS.has(format) && !info.isNull()) patchChars(info, false);
    },
  }),
];

console.log(
  `[cameraserver-hook] ${hooked.filter(Boolean).length}/${hooked.length} hooks applied`,
);
