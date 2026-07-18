#!/usr/bin/env node
// scripts/build_emoji_json.mjs
// Generated from @emoji-mart/data@1.2.1 (Emoji 15.1)
//
// One-time transform script: installs @emoji-mart/data in a temp directory,
// walks the emoji dataset, and emits a bundled JSON resource for the
// Ritoras keyboard extension.
//
// Usage: node scripts/build_emoji_json.mjs

import { execSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..');

// Category id → English display name mapping
// Matches the brief's specification (8 categories from emoji-mart data).
const CATEGORY_NAMES = {
  people: 'People & Body',
  nature: 'Animals & Nature',
  foods: 'Food & Drink',
  activity: 'Activities',
  places: 'Travel & Places',
  objects: 'Objects',
  symbols: 'Symbols',
  flags: 'Flags',
};

function stripTrailingVS16(str) {
  // Strip trailing variation selector U+FE0F (e.g., ☺️ → ☺)
  return str.endsWith('\uFE0F') ? str.slice(0, -1) : str;
}

async function main() {
  // Install @emoji-mart/data in a temp directory
  const tmpDir = mkdtempSync(join(tmpdir(), 'emoji-mart-'));
  try {
    execSync('npm init -y > /dev/null 2>&1', { cwd: tmpDir, stdio: 'ignore' });
    execSync('npm install @emoji-mart/data@1.2.1 > /dev/null 2>&1', {
      cwd: tmpDir,
      stdio: 'ignore',
      timeout: 60000,
    });

    const req = createRequire(join(tmpDir, 'node_modules/@emoji-mart/data/package.json'));
    const data = req('@emoji-mart/data');

    const categories = data.categories;
    const emojis = data.emojis;

    // Build output structure
    const outputCategories = [];
    const skinToneCapableSet = new Set();

    for (const cat of categories) {
      const displayName = CATEGORY_NAMES[cat.id];
      if (!displayName) {
        console.error(`Warning: unknown category id "${cat.id}", skipping`);
        continue;
      }

      const entries = [];

      for (const emojiId of cat.emojis) {
        const emoji = emojis[emojiId];
        if (!emoji) {
          console.error(`Warning: emoji "${emojiId}" referenced in category "${cat.id}" not found in emojis map`);
          continue;
        }

        const skins = emoji.skins;
        if (!skins || skins.length === 0) {
          console.error(`Warning: emoji "${emojiId}" has no skins`);
          continue;
        }

        // Base char is always the first skin entry
        const char = stripTrailingVS16(skins[0].native);

        // Lowercase the name (emoji-mart uses title case)
        const name = (emoji.name || emojiId).toLowerCase();

        // Keywords array (already lowercase)
        const keywords = emoji.keywords || [];

        // Skin-tone capable if more than 1 skin (base + at least 1 tone)
        const hasSkins = skins.length > 1;
        if (hasSkins) {
          skinToneCapableSet.add(char);
        }

        entries.push({ char, name, keywords, hasSkins });
      }

      outputCategories.push({
        id: cat.id,
        name: displayName,
        emojis: entries,
      });
    }

    const output = {
      categories: outputCategories,
      skinToneCapable: [...skinToneCapableSet].sort(),
    };

    // Count total emojis
    const totalEmojis = outputCategories.reduce((sum, c) => sum + c.emojis.length, 0);

    // Sanity checks
    console.log(`Total emojis: ${totalEmojis}`);
    console.log(`Categories: ${outputCategories.length} (${outputCategories.map((c) => c.id).join(', ')})`);
    console.log(`Skin-tone capable: ${output.skinToneCapable.length}`);
    console.log(`Output size: ~${JSON.stringify(output).length} bytes`);

    // Check for duplicates within each category
    for (const cat of outputCategories) {
      const chars = cat.emojis.map((e) => e.char);
      const uniqueChars = new Set(chars);
      if (chars.length !== uniqueChars.size) {
        console.error(`ERROR: Duplicate chars in category "${cat.id}"`);
        process.exit(1);
      }
    }

    // Write output file
    const outputPath = join(REPO_ROOT, 'keyboard/Sources/Emoji/Resources/emojis.json');
    writeFileSync(outputPath, JSON.stringify(output, null, 2) + '\n');
    console.log(`\nWritten to ${outputPath}`);
  } finally {
    // Clean up temp dir
    try {
      execSync(`rm -rf "${tmpDir}"`, { stdio: 'ignore' });
    } catch {
      // best-effort cleanup
    }
  }
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
