#!/usr/bin/env tsx
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import JSZip from "jszip";
import { chromium, type Page } from "playwright";
import { formatValidationReport, validateImage, type ValidationResult } from "./validate-exports";

type CliOptions = {
  url: string;
  outDir: string;
  width: number;
  height: number;
  selector: string;
  locale: string;
  device: string;
  theme: string;
  waitMs: number;
  zipPath?: string;
  noZip: boolean;
  allowExternal: boolean;
};

type ExportManifestItem = {
  filename: string;
  path: string;
  locale: string;
  device: string;
  theme: string;
  slide: number;
  slideId: string;
  width: number;
  height: number;
  renderer: "playwright";
  createdAt: string;
  validation: ValidationResult;
};

function usage(): never {
  throw new Error(
    [
      "Usage:",
      "  tsx scripts/export-playwright.ts --url http://127.0.0.1:3000 --width 1320 --height 2868 [options]",
      "",
      "Options:",
      "  --out <dir>              Export root, default exports/app-store-screenshots",
      "  --selector <selector>    Slide selector, default [data-export-slide]",
      "  --locale <locale>        Locale label, default en-US",
      "  --device <device>        Device folder label, default iphone-6.9",
      "  --theme <theme>          Theme label, default default",
      "  --wait-ms <ms>           Extra wait after load, default 0",
      "  --zip <path>             Zip path, default <out>/app-store-screenshots-WxH.zip",
      "  --no-zip                 Do not create a zip",
      "  --allow-external         Do not block non-localhost requests",
      "",
      "The page must render final-size slide elements matching --selector.",
      "Each slide should have data-export-slide=\"01\" or similar for stable filenames.",
    ].join("\n")
  );
}

function parseArgs(argv: string[]): CliOptions {
  const opts: CliOptions = {
    url: "",
    outDir: "exports/app-store-screenshots",
    width: 0,
    height: 0,
    selector: "[data-export-slide]",
    locale: "en-US",
    device: "iphone-6.9",
    theme: "default",
    waitMs: 0,
    noZip: false,
    allowExternal: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      const value = argv[++i];
      if (!value) usage();
      return value;
    };

    if (arg === "--url") opts.url = next();
    else if (arg === "--out") opts.outDir = next();
    else if (arg === "--width") opts.width = Number(next());
    else if (arg === "--height") opts.height = Number(next());
    else if (arg === "--selector") opts.selector = next();
    else if (arg === "--locale") opts.locale = next();
    else if (arg === "--device") opts.device = next();
    else if (arg === "--theme") opts.theme = next();
    else if (arg === "--wait-ms") opts.waitMs = Number(next());
    else if (arg === "--zip") opts.zipPath = next();
    else if (arg === "--no-zip") opts.noZip = true;
    else if (arg === "--allow-external") opts.allowExternal = true;
    else if (arg === "--help" || arg === "-h") usage();
    else throw new Error(`Unknown argument: ${arg}`);
  }

  if (!opts.url || !Number.isFinite(opts.width) || !Number.isFinite(opts.height) || opts.width <= 0 || opts.height <= 0) {
    usage();
  }

  return opts;
}

function slug(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "") || "slide";
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function portablePath(value: string): string {
  return value.split(path.sep).join(path.posix.sep);
}

export function isLoopbackTarget(url: URL): boolean {
  const hostname = url.hostname.toLowerCase();
  return (
    (url.protocol === "http:" || url.protocol === "https:") &&
    (hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]" || hostname === "::1")
  );
}

export function shouldAllowRequest(requestUrl: string, targetUrl: URL, allowExternal: boolean): boolean {
  if (allowExternal) return true;

  const request = new URL(requestUrl);
  return request.protocol === "data:" || request.protocol === "blob:" || request.origin === targetUrl.origin;
}

async function waitForImages(page: Page) {
  await page.evaluate(async () => {
    await document.fonts.ready;
    await Promise.all(
      Array.from(document.images).map((img) => {
        if (img.complete && img.naturalWidth > 0) return Promise.resolve();
        return new Promise<void>((resolve, reject) => {
          img.addEventListener("load", () => resolve(), { once: true });
          img.addEventListener("error", () => reject(new Error(`Image failed to load: ${img.currentSrc || img.src}`)), {
            once: true,
          });
        });
      })
    );
  });
}

async function makeContactSheet(items: ExportManifestItem[], outPath: string, rootDir: string) {
  const thumbW = 220;
  const thumbH = Math.max(160, Math.round((thumbW * items[0].height) / items[0].width));
  const cols = Math.min(4, Math.max(1, items.length));
  const cellW = thumbW + 36;
  const cellH = thumbH + 76;
  const width = cols * cellW + 32;

  const cards = await Promise.all(
    items.map(async (item) => {
      const buf = await readFile(path.resolve(rootDir, item.path));
      const dataUrl = `data:image/png;base64,${buf.toString("base64")}`;
      return `
        <figure>
          <img src="${dataUrl}" />
          <figcaption>
            <strong>${escapeHtml(item.slideId)}</strong> ${escapeHtml(item.device)} ${escapeHtml(item.locale)}<br />
            ${item.width}x${item.height}<br />
            ${escapeHtml(item.filename)}
          </figcaption>
        </figure>
      `;
    })
  );

  const html = `
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8" />
        <style>
          html, body { margin: 0; background: #fff; }
          body {
            width: ${width}px;
            padding: 16px;
            box-sizing: border-box;
            font: 14px ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            color: #111;
          }
          main {
            display: grid;
            grid-template-columns: repeat(${cols}, ${thumbW}px);
            gap: 28px 36px;
          }
          figure { margin: 0; }
          img {
            display: block;
            width: ${thumbW}px;
            height: ${thumbH}px;
            object-fit: cover;
            object-position: top;
            background: #fff;
            border: 1px solid #ddd;
          }
          figcaption { margin-top: 8px; line-height: 1.35; overflow-wrap: anywhere; }
        </style>
      </head>
      <body><main>${cards.join("\n")}</main></body>
    </html>
  `;

  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width, height: Math.max(720, Math.ceil(items.length / cols) * cellH + 32) } });
    await page.setContent(html, { waitUntil: "load" });
    await page.screenshot({ path: outPath, type: "jpeg", quality: 92, fullPage: true });
  } finally {
    await browser.close();
  }
}

async function createZip(rootDir: string, manifest: ExportManifestItem[], zipPath: string) {
  const zip = new JSZip();
  const files = [
    path.join(rootDir, "_manifest.json"),
    path.join(rootDir, "_validation.txt"),
    path.join(rootDir, "_contact-sheet.jpg"),
    ...manifest.map((item) => path.resolve(rootDir, item.path)),
  ];

  for (const file of files) {
    const relative = portablePath(path.relative(rootDir, file));
    zip.file(relative, await readFile(file));
  }

  const buffer = await zip.generateAsync({ type: "nodebuffer", compression: "DEFLATE" });
  await mkdir(path.dirname(zipPath), { recursive: true });
  await writeFile(zipPath, buffer);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const targetUrl = new URL(opts.url);
  if (!opts.allowExternal && !isLoopbackTarget(targetUrl)) {
    throw new Error("--url must use localhost, 127.0.0.1, or [::1] unless --allow-external is set");
  }

  const outRoot = path.resolve(opts.outDir);
  const screenshotDir = path.join(outRoot, "screenshots", slug(opts.locale), slug(opts.device));
  const manifestPath = path.join(outRoot, "_manifest.json");
  const validationPath = path.join(outRoot, "_validation.txt");
  const contactSheetPath = path.join(outRoot, "_contact-sheet.jpg");
  const zipPath = path.resolve(opts.zipPath || path.join(outRoot, `app-store-screenshots-${opts.width}x${opts.height}.zip`));

  await rm(screenshotDir, { recursive: true, force: true });
  await Promise.all([
    rm(manifestPath, { force: true }),
    rm(validationPath, { force: true }),
    rm(contactSheetPath, { force: true }),
    ...(opts.noZip ? [] : [rm(zipPath, { force: true })]),
  ]);
  await mkdir(screenshotDir, { recursive: true });

  const browser = await chromium.launch();
  const manifest: ExportManifestItem[] = [];
  const allowedSizes = new Set([`${opts.width}x${opts.height}`]);
  const createdAt = new Date().toISOString();

  try {
    const page = await browser.newPage({
      viewport: { width: opts.width, height: opts.height },
      deviceScaleFactor: 1,
    });

    if (!opts.allowExternal) {
      await page.route("**/*", (route) => {
        const requestUrl = route.request().url();
        return shouldAllowRequest(requestUrl, targetUrl, opts.allowExternal) ? route.continue() : route.abort();
      });
    }

    await page.goto(targetUrl.href, { waitUntil: "networkidle" });
    await waitForImages(page);
    if (opts.waitMs > 0) await page.waitForTimeout(opts.waitMs);

    const slides = page.locator(opts.selector);
    const count = await slides.count();
    if (count === 0) throw new Error(`No export slides found with selector ${opts.selector}`);

    for (let i = 0; i < count; i++) {
      const slide = slides.nth(i);
      const rawId = (await slide.getAttribute("data-export-slide")) || String(i + 1).padStart(2, "0");
      const slideId = slug(rawId);
      const filename = `${String(i + 1).padStart(2, "0")}-${slideId}-${slug(opts.locale)}-${slug(opts.device)}-${opts.width}x${opts.height}.png`;
      const outPath = path.join(screenshotDir, filename);
      const relativePath = portablePath(path.relative(outRoot, outPath));

      await slide.screenshot({ path: outPath, omitBackground: false });
      const validation = {
        ...(await validateImage(outPath, allowedSizes)),
        file: relativePath,
      };

      manifest.push({
        filename,
        path: relativePath,
        locale: opts.locale,
        device: opts.device,
        theme: opts.theme,
        slide: i + 1,
        slideId,
        width: opts.width,
        height: opts.height,
        renderer: "playwright",
        createdAt,
        validation,
      });
    }
  } finally {
    await browser.close();
  }

  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  await writeFile(validationPath, `${formatValidationReport(manifest.map((item) => item.validation))}\n`);
  await makeContactSheet(manifest, contactSheetPath, outRoot);

  if (!opts.noZip) {
    await createZip(outRoot, manifest, zipPath);
  }

  if (manifest.some((item) => item.validation.status === "fail")) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
