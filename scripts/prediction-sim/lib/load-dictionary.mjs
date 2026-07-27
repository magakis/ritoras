import fs from 'node:fs';
import path from 'node:path';

const DICT_PATH = path.resolve(
  process.cwd(),
  'keyboard/Sources/Prediction/Resources/frequency_dictionary_en_wordfreq_50k.txt'
);

/** Loads the bundled frequency dictionary into an array of {word, count}. */
export function loadDictionary(dictPath = DICT_PATH) {
  const content = fs.readFileSync(dictPath, 'utf8');
  return content.split('\n')
    .map(line => line.trim())
    .filter(Boolean)
    .map(line => {
      const spaceIndex = line.lastIndexOf(' ');
      if (spaceIndex < 0) return null;
      const word = line.slice(0, spaceIndex);
      const count = Number.parseInt(line.slice(spaceIndex + 1), 10);
      return Number.isNaN(count) ? null : { word, count };
    })
    .filter(Boolean);
}
