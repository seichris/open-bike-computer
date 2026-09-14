// Usage: NODE_PATH=<node_modules containing sharp> node this.cjs <package/3x2>
// Source: country-flag-icons@1.6.20 (MIT). Rasterization is offline.
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');
async function main() {
  const source = process.argv[2];
  const files = fs.readdirSync(source).filter(f => /^[A-Z]{2}\.svg$/.test(f)).sort();
  let result = '// Generated from country-flag-icons@1.6.20; see tools/world-radio-flags/LICENSE.\n#include "worldRadioFlags.hpp"\n#include <cstring>\nnamespace world_radio_flags {\n';
  result += 'struct Flag { char code[3]; uint16_t pixels[WIDTH * HEIGHT]; };\nstatic const Flag flags[] = {\n';
  for (const file of files) {
    const rgb = await sharp(path.join(source, file)).resize(24, 16).flatten({background: '#ffffff'}).removeAlpha().raw().toBuffer();
    const pixels = [];
    for (let i = 0; i < rgb.length; i += 3) pixels.push('0x' + (((rgb[i] >> 3) << 11) | ((rgb[i+1] >> 2) << 5) | (rgb[i+2] >> 3)).toString(16).padStart(4, '0'));
    result += `{"${file.slice(0,2)}", {${pixels.join(',')}}},\n`;
  }
  result += '};\nconst uint16_t *find(const char *code) {\n if (!code || !code[0] || !code[1] || code[2]) return nullptr;\n for (const auto &flag : flags) if (std::strcmp(code, flag.code) == 0) return flag.pixels;\n return nullptr;\n}\n}\n';
  fs.writeFileSync(path.join(__dirname, '../lib/gui/src/worldRadioFlags.cpp'), result);
  console.log(`Generated ${files.length} flags, ${files.length * 24 * 16 * 2} bitmap bytes`);
}
main().catch(error => { console.error(error); process.exit(1); });
