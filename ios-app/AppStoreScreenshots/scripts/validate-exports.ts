#!/usr/bin/env tsx
import { readdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

export type ValidationStatus = "pass" | "fail";

export type ImageInfo = {
  width: number;
  height: number;
  format: "png" | "jpeg";
  hasAlphaChannel: boolean;
};

export type ValidationResult = {
  file: string;
  status: ValidationStatus;
  width?: number;
  height?: number;
  format?: "png" | "jpeg";
  hasAlphaChannel?: boolean;
  errors: string[];
};

type CliOptions = {
  dir: string;
  output?: string;
  json?: string;
  allow: Set<string>;
};

function usage(): never {
  throw new Error(
    [
      "Usage:",
      "  tsx scripts/validate-exports.ts --dir <exports-dir> --allow 1320x2868 [--allow 2064x2752] [--output _validation.txt] [--json validation.json]",
      "",
      "Validates .png/.jpg/.jpeg files recursively. PNG files must be opaque.",
    ].join("\n")
  );
}

function parseArgs(argv: string[]): CliOptions {
  const opts: CliOptions = { dir: "", allow: new Set() };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      const value = argv[++i];
      if (!value) usage();
      return value;
    };

    if (arg === "--dir") opts.dir = next();
    else if (arg === "--output") opts.output = next();
    else if (arg === "--json") opts.json = next();
    else if (arg === "--allow") opts.allow.add(normalizeSize(next()));
    else if (arg === "--help" || arg === "-h") usage();
    else throw new Error(`Unknown argument: ${arg}`);
  }

  if (!opts.dir) usage();
  return opts;
}

function normalizeSize(value: string): string {
  const match = value.trim().match(/^(\d+)[xX](\d+)$/);
  if (!match) throw new Error(`Invalid size "${value}", expected WIDTHxHEIGHT`);
  return `${Number(match[1])}x${Number(match[2])}`;
}

async function walkFiles(root: string): Promise<string[]> {
  const entries = (await readdir(root, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name));
  const files: string[] = [];

  for (const entry of entries) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) files.push(...(await walkFiles(fullPath)));
    else if (entry.isFile()) files.push(fullPath);
  }

  return files;
}

function extensionKind(filePath: string): "png" | "jpeg" | undefined {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === ".png") return "png";
  if (ext === ".jpg" || ext === ".jpeg") return "jpeg";
  return undefined;
}

function readPngInfo(filePath: string, buf: Buffer): ImageInfo {
  if (buf.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a") {
    throw new Error(`${filePath} is not a PNG`);
  }

  let offset = 8;
  let width = 0;
  let height = 0;
  let colorType = -1;
  let hasTRNS = false;
  let sawIHDR = false;
  let sawIEND = false;

  while (offset + 12 <= buf.length) {
    const length = buf.readUInt32BE(offset);
    const chunkEnd = offset + 12 + length;
    if (chunkEnd > buf.length) throw new Error(`${filePath} contains a truncated PNG chunk`);

    const type = buf.subarray(offset + 4, offset + 8).toString("ascii");
    const dataOffset = offset + 8;

    if (!sawIHDR) {
      if (type !== "IHDR" || length !== 13) throw new Error(`${filePath} does not start with a valid IHDR chunk`);
      width = buf.readUInt32BE(dataOffset);
      height = buf.readUInt32BE(dataOffset + 4);
      colorType = buf.readUInt8(dataOffset + 9);
      sawIHDR = true;
    } else if (type === "IHDR") {
      throw new Error(`${filePath} contains more than one IHDR chunk`);
    }

    if (type === "tRNS") hasTRNS = true;
    if (type === "IEND") {
      sawIEND = true;
      break;
    }

    offset = chunkEnd;
  }

  if (!sawIHDR || !sawIEND || width <= 0 || height <= 0) {
    throw new Error(`${filePath} does not contain a complete PNG structure`);
  }

  if (![0, 2, 3, 4, 6].includes(colorType)) {
    throw new Error(`${filePath} uses unsupported PNG color type ${colorType}`);
  }

  return {
    width,
    height,
    format: "png",
    hasAlphaChannel: colorType === 4 || colorType === 6 || hasTRNS,
  };
}

function readJpegInfo(filePath: string, buf: Buffer): ImageInfo {
  if (buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8) {
    throw new Error(`${filePath} is not a JPEG`);
  }

  let offset = 2;
  while (offset < buf.length) {
    while (offset < buf.length && buf[offset] !== 0xff) offset++;
    while (offset < buf.length && buf[offset] === 0xff) offset++;
    if (offset >= buf.length) break;
    const marker = buf[offset++];

    if (marker === 0xd9 || marker === 0xda) break;
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > buf.length) break;

    const length = buf.readUInt16BE(offset);
    if (length < 2 || offset + length > buf.length) break;

    const isSof =
      (marker >= 0xc0 && marker <= 0xc3) ||
      (marker >= 0xc5 && marker <= 0xc7) ||
      (marker >= 0xc9 && marker <= 0xcb) ||
      (marker >= 0xcd && marker <= 0xcf);

    if (isSof) {
      if (length < 8) throw new Error(`${filePath} contains an invalid JPEG SOF segment`);
      const height = buf.readUInt16BE(offset + 3);
      const width = buf.readUInt16BE(offset + 5);
      if (width <= 0 || height <= 0) throw new Error(`${filePath} has invalid JPEG dimensions`);

      return {
        width,
        height,
        format: "jpeg",
        hasAlphaChannel: false,
      };
    }

    offset += length;
  }

  throw new Error(`${filePath} does not contain a readable JPEG size marker`);
}

export async function readImageInfo(filePath: string): Promise<ImageInfo> {
  const buf = await readFile(filePath);
  const kind = extensionKind(filePath);

  if (kind === "png") return readPngInfo(filePath, buf);
  if (kind === "jpeg") return readJpegInfo(filePath, buf);
  throw new Error(`${filePath} must be .png, .jpg, or .jpeg`);
}

export async function validateImage(filePath: string, allowedSizes = new Set<string>()): Promise<ValidationResult> {
  const errors: string[] = [];

  try {
    const info = await readImageInfo(filePath);
    const size = `${info.width}x${info.height}`;

    if (allowedSizes.size > 0 && !allowedSizes.has(size)) {
      errors.push(`unexpected size ${size}; expected one of ${Array.from(allowedSizes).join(", ")}`);
    }

    if (info.format === "png" && info.hasAlphaChannel) {
      errors.push("PNG has alpha channel or tRNS transparency");
    }

    return {
      file: filePath,
      status: errors.length ? "fail" : "pass",
      ...info,
      errors,
    };
  } catch (error) {
    return {
      file: filePath,
      status: "fail",
      errors: [error instanceof Error ? error.message : String(error)],
    };
  }
}

export function formatValidationReport(results: ValidationResult[]): string {
  return results
    .map((result) => {
      const size = result.width && result.height ? `${result.width}x${result.height}` : "unknown-size";
      const alpha = result.hasAlphaChannel ? "alpha" : "opaque";
      const detail = result.errors.length ? ` - ${result.errors.join("; ")}` : "";
      return `${result.status.toUpperCase()} ${size} ${result.format ?? "unknown"} ${alpha} ${result.file}${detail}`;
    })
    .join("\n");
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const root = path.resolve(opts.dir);
  const rootStat = await stat(root);
  if (!rootStat.isDirectory()) throw new Error(`${root} is not a directory`);

  const allFiles = await walkFiles(root);
  const imageFiles = allFiles.filter((file) => Boolean(extensionKind(file)));
  if (imageFiles.length === 0) throw new Error(`No .png/.jpg/.jpeg files found under ${root}`);

  const reportRoot = path.dirname(root);
  const results = (await Promise.all(imageFiles.map((file) => validateImage(file, opts.allow)))).map((result) => ({
    ...result,
    file: path.relative(reportRoot, result.file).split(path.sep).join(path.posix.sep),
  }));
  const report = formatValidationReport(results);

  if (opts.output) await writeFile(path.resolve(opts.output), `${report}\n`);
  else process.stdout.write(`${report}\n`);

  if (opts.json) await writeFile(path.resolve(opts.json), `${JSON.stringify(results, null, 2)}\n`);

  if (results.some((result) => result.status === "fail")) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
