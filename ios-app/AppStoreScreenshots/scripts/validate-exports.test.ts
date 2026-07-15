import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { readImageInfo, validateImage } from "./validate-exports";

function pngChunk(type: string, data = Buffer.alloc(0)): Buffer {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  return Buffer.concat([length, Buffer.from(type, "ascii"), data, Buffer.alloc(4)]);
}

function makePng(width: number, height: number, colorType: number, chunks: Buffer[] = []): Buffer {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = colorType;

  return Buffer.concat([
    Buffer.from("89504e470d0a1a0a", "hex"),
    pngChunk("IHDR", ihdr),
    ...chunks,
    pngChunk("IEND"),
  ]);
}

function makeJpeg(width: number, height: number): Buffer {
  return Buffer.from([
    0xff, 0xd8,
    0xff, 0xc0, 0x00, 0x11, 0x08,
    (height >> 8) & 0xff, height & 0xff,
    (width >> 8) & 0xff, width & 0xff,
    0x03,
    0x01, 0x11, 0x00,
    0x02, 0x11, 0x00,
    0x03, 0x11, 0x00,
    0xff, 0xd9,
  ]);
}

test("reads JPEG dimensions from the SOF segment", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "app-store-jpeg-"));
  const file = path.join(dir, "fixture.jpg");

  try {
    await writeFile(file, makeJpeg(800, 720));
    assert.deepEqual(await readImageInfo(file), {
      width: 800,
      height: 720,
      format: "jpeg",
      hasAlphaChannel: false,
    });

    const result = await validateImage(file, new Set(["800x720"]));
    assert.equal(result.status, "pass");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("only treats a real tRNS chunk as PNG transparency", async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "app-store-png-"));
  const opaque = path.join(dir, "opaque.png");
  const transparent = path.join(dir, "transparent.png");

  try {
    await writeFile(opaque, makePng(1242, 2688, 2, [pngChunk("tEXt", Buffer.from("contains tRNS text"))]));
    await writeFile(transparent, makePng(1242, 2688, 2, [pngChunk("tRNS", Buffer.from([0, 0, 0, 0, 0, 0]))]));

    assert.equal((await readImageInfo(opaque)).hasAlphaChannel, false);
    assert.equal((await readImageInfo(transparent)).hasAlphaChannel, true);
    assert.equal((await validateImage(transparent, new Set(["1242x2688"]))).status, "fail");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
