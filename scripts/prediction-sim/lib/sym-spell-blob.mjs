import fs from 'node:fs';
import path from 'node:path';
import { SymSpell, levenshteinDistance } from './symspell.mjs';

export const SYMSPELL_BLOB_MAGIC = 'RSS1';
export const SYMSPELL_BLOB_FORMAT_VERSION = 1;
export const SYMSPELL_MAX_EDIT_DISTANCE = 2;
export const SYMSPELL_PREFIX_LENGTH = 7;
export const SYMSPELL_MIN_WORD_FREQ = 1500;
export const SYMSPELL_BLOB_HEADER_BYTES = 0x40;

const UINT32_MAX = 0xffff_ffff;
const INT32_MIN = -0x8000_0000;
const INT32_MAX = 0x7fff_ffff;
const FNV1A64_MASK = 0xffff_ffff_ffff_ffffn;

export const FNV1A64_OFFSET_BASIS = 14695981039346656037n;
export const FNV1A64_PRIME = 1099511628211n;

/**
 * Computes the FNV-1a-64 digest used by both the source and blob checksums.
 * @param {Uint8Array|Buffer} bytes
 * @returns {bigint}
 */
export function fnv1a64(bytes) {
  if (!(bytes instanceof Uint8Array)) {
    throw new TypeError('fnv1a64 expects a Uint8Array or Buffer');
  }

  let hash = FNV1A64_OFFSET_BASIS;
  for (const byte of bytes) {
    hash ^= BigInt(byte);
    hash = (hash * FNV1A64_PRIME) & FNV1A64_MASK;
  }
  return hash;
}

function align(value, alignment) {
  return Math.ceil(value / alignment) * alignment;
}

function assertUint32(value, name) {
  if (!Number.isInteger(value) || value < 0 || value > UINT32_MAX) {
    throw new RangeError(`${name} does not fit in u32: ${value}`);
  }
}

function assertInt32(value, name) {
  if (!Number.isInteger(value) || value < INT32_MIN || value > INT32_MAX) {
    throw new RangeError(`${name} does not fit in i32: ${value}`);
  }
}

function assertNonNegativeInt32(value, name) {
  if (!Number.isInteger(value) || value < 0 || value > INT32_MAX) {
    throw new RangeError(`${name} does not fit in a non-negative i32: ${value}`);
  }
}

function normalizeLanguage(lang) {
  if (lang !== 'en' && lang !== 'el') {
    throw new Error(`unsupported SymSpell blob language: ${lang}`);
  }
  return lang;
}

function languageBytes(lang) {
  const bytes = Buffer.alloc(4);
  bytes.write(lang, 0, 2, 'ascii');
  return bytes;
}

function languageFromPath(filePath) {
  const name = path.basename(filePath);
  const match = name.match(/(?:^|_)((?:en)|(?:el))(?:_|\.)/);
  return match ? match[1] : undefined;
}

function normalizeReadOptions(pathOrBuffer, options) {
  if (typeof options === 'string') {
    return { expectedLang: options };
  }

  const normalized = options ? { ...options } : {};
  if (normalized.expectedLang === undefined && typeof pathOrBuffer === 'string') {
    normalized.expectedLang = languageFromPath(pathOrBuffer);
  }
  if (normalized.expectedLang === undefined && normalized.expectedLanguage !== undefined) {
    normalized.expectedLang = normalized.expectedLanguage;
  }
  return normalized;
}

function readInput(pathOrBuffer) {
  if (typeof pathOrBuffer === 'string' || pathOrBuffer instanceof URL) {
    return fs.readFileSync(pathOrBuffer);
  }
  if (Buffer.isBuffer(pathOrBuffer)) {
    return pathOrBuffer;
  }
  if (pathOrBuffer instanceof ArrayBuffer) {
    return Buffer.from(pathOrBuffer);
  }
  if (pathOrBuffer instanceof Uint8Array) {
    return Buffer.from(pathOrBuffer.buffer, pathOrBuffer.byteOffset, pathOrBuffer.byteLength);
  }
  throw new TypeError('readSymSpellBlob expects a path, Buffer, or Uint8Array');
}

function readHeaderBytes(pathOrBuffer) {
  if (typeof pathOrBuffer !== 'string' && !(pathOrBuffer instanceof URL)) {
    return readInput(pathOrBuffer).subarray(0, SYMSPELL_BLOB_HEADER_BYTES);
  }

  const descriptor = fs.openSync(pathOrBuffer, 'r');
  try {
    const header = Buffer.alloc(SYMSPELL_BLOB_HEADER_BYTES);
    const bytesRead = fs.readSync(descriptor, header, 0, header.length, 0);
    if (bytesRead !== header.length) {
      throw new Error(`truncated SymSpell blob header: ${bytesRead} bytes`);
    }
    return header;
  } finally {
    fs.closeSync(descriptor);
  }
}

function parseHeader(data) {
  if (data.length < SYMSPELL_BLOB_HEADER_BYTES) {
    throw new Error('truncated SymSpell blob header');
  }

  const magic = data.subarray(0, 4).toString('ascii');
  const version = data.readUInt16LE(4);
  const maxEditDistance = data.readUInt8(6);
  const prefixLength = data.readUInt8(7);
  const languageBytesValue = data.subarray(8, 12);
  const language = languageBytesValue.subarray(0, 2).toString('ascii');

  return {
    magic,
    formatVersion: version,
    maxEditDistance,
    prefixLength,
    lang: language,
    langBytesValid: languageBytesValue[2] === 0 && languageBytesValue[3] === 0,
    wordCount: data.readUInt32LE(0x0c),
    deleteKeyCount: data.readUInt32LE(0x10),
    deleteValueCount: data.readUInt32LE(0x14),
    stringPoolBytes: data.readUInt32LE(0x18),
    wordlistFnv1a64: data.readBigUInt64LE(0x1c),
    reserved: data.subarray(0x24, 0x40),
  };
}

/**
 * Reads only the fixed header. This is used by the cheap freshness check.
 * @param {string|Buffer|Uint8Array} pathOrBuffer
 * @returns {object}
 */
export function readSymSpellBlobHeader(pathOrBuffer) {
  return parseHeader(readHeaderBytes(pathOrBuffer));
}

function computeLayout(header) {
  let offset = SYMSPELL_BLOB_HEADER_BYTES;
  const sections = {};

  const addSection = (name, bytes) => {
    sections[name] = { offset, bytes };
    offset += bytes;
  };

  addSection('wordOffsets', 4 * (header.wordCount + 1));
  addSection('sortedWordIdx', 4 * header.wordCount);
  addSection('counts', 4 * header.wordCount);
  addSection('deleteKeyOffsets', 4 * (header.deleteKeyCount + 1));
  addSection('deleteOffsets', 4 * (header.deleteKeyCount + 1));
  addSection('deleteValues', 4 * header.deleteValueCount);
  addSection('stringPool', header.stringPoolBytes);

  sections.sectionEnd = align(offset, 8);
  sections.blobFnv1a64 = sections.sectionEnd;
  sections.fileSize = sections.blobFnv1a64 + 8;
  return sections;
}

function validateHeader(header, options) {
  if (header.magic !== SYMSPELL_BLOB_MAGIC) {
    throw new Error(`invalid SymSpell blob magic: ${JSON.stringify(header.magic)}`);
  }
  if (header.formatVersion !== (options.expectedFormatVersion ?? SYMSPELL_BLOB_FORMAT_VERSION)) {
    throw new Error(`unsupported SymSpell blob format version: ${header.formatVersion}`);
  }
  if (!header.langBytesValid) {
    throw new Error('invalid SymSpell blob language bytes');
  }
  if (header.lang !== 'en' && header.lang !== 'el') {
    throw new Error(`invalid SymSpell blob language: ${JSON.stringify(header.lang)}`);
  }
  if (options.expectedLang !== undefined) {
    const expectedLang = normalizeLanguage(options.expectedLang);
    if (header.lang !== expectedLang) {
      throw new Error(`unexpected SymSpell blob language: ${header.lang}`);
    }
  }
  if (header.maxEditDistance !== (options.expectedMaxEditDistance ?? SYMSPELL_MAX_EDIT_DISTANCE)) {
    throw new Error(`unexpected SymSpell max edit distance: ${header.maxEditDistance}`);
  }
  if (header.prefixLength !== (options.expectedPrefixLength ?? SYMSPELL_PREFIX_LENGTH)) {
    throw new Error(`unexpected SymSpell prefix length: ${header.prefixLength}`);
  }

  const dimensions = [
    ['wordCount', header.wordCount],
    ['deleteKeyCount', header.deleteKeyCount],
    ['deleteValueCount', header.deleteValueCount],
    ['stringPoolBytes', header.stringPoolBytes],
  ];
  for (const [name, value] of dimensions) {
    if (value <= 0) {
      throw new Error(`invalid SymSpell blob ${name}: ${value}`);
    }
  }

  if (options.expectedWordlistFnv1a64 !== undefined
      && header.wordlistFnv1a64 !== BigInt(options.expectedWordlistFnv1a64)) {
    throw new Error('SymSpell blob source wordlist checksum mismatch');
  }
}

function readUint32Array(data, offset, length) {
  const output = new Uint32Array(length);
  for (let index = 0; index < length; index++) {
    output[index] = data.readUInt32LE(offset + index * 4);
  }
  return output;
}

function readInt32Array(data, offset, length) {
  const output = new Int32Array(length);
  for (let index = 0; index < length; index++) {
    output[index] = data.readInt32LE(offset + index * 4);
  }
  return output;
}

function validateOffsets(data, layout, header, views) {
  const fixedOffsets = [
    layout.wordOffsets.offset,
    layout.sortedWordIdx.offset,
    layout.counts.offset,
    layout.deleteKeyOffsets.offset,
    layout.deleteOffsets.offset,
    layout.deleteValues.offset,
    layout.stringPool.offset,
    layout.blobFnv1a64,
  ];
  if (fixedOffsets.some(offset => offset % 4 !== 0)) {
    throw new Error('SymSpell blob section is not 4-byte aligned');
  }
  if (layout.blobFnv1a64 % 8 !== 0) {
    throw new Error('SymSpell blob checksum is not 8-byte aligned');
  }

  const checkMonotonic = (values, sentinel, name) => {
    if (values[0] < 0) {
      throw new Error(`${name} contains a negative offset`);
    }
    if (values[values.length - 1] !== sentinel) {
      throw new Error(`invalid ${name} sentinel`);
    }
    for (let index = 1; index < values.length; index++) {
      if (values[index] < values[index - 1]) {
        throw new Error(`${name} is not monotonic`);
      }
    }
  };

  checkMonotonic(views.deleteKeyOffsets, header.stringPoolBytes, 'deleteKeyOffsets');
  checkMonotonic(views.deleteOffsets, header.deleteValueCount, 'deleteOffsets');
  if (views.wordOffsets[0] !== 0) throw new Error('wordOffsets must start at zero');
  if (views.deleteOffsets[0] !== 0) throw new Error('deleteOffsets must start at zero');

  for (const index of views.sortedWordIdx) {
    if (index >= header.wordCount) {
      throw new Error(`sorted word index out of range: ${index}`);
    }
  }
  for (const index of views.deleteValues) {
    if (index < 0 || index >= header.wordCount) {
      throw new Error(`delete value out of range: ${index}`);
    }
  }
  const pool = data.subarray(layout.stringPool.offset, layout.stringPool.offset + header.stringPoolBytes);
  const pooledBytes = (offsets, name) => {
    for (let index = 0; index + 1 < offsets.length; index++) {
      const start = offsets[index];
      const end = offsets[index + 1];
      if (end <= start || pool[end - 1] !== 0) {
        throw new Error(`invalid ${name} string boundary at ${index}`);
      }
    }
  };
  pooledBytes(views.deleteKeyOffsets, 'delete key');

  const wordBytesAt = index => {
    const start = views.wordOffsets[index];
    const end = pool.indexOf(0, start);
    if (end < 0) throw new Error(`unterminated word at ${index}`);
    return pool.subarray(start, end);
  };
  for (let index = 0; index < header.wordCount; index++) {
    const terminator = pool.indexOf(0, views.wordOffsets[index]);
    if (terminator < 0) throw new Error(`unterminated word at ${index}`);
    if (index + 1 < header.wordCount && views.wordOffsets[index + 1] !== terminator + 1) {
      throw new Error(`invalid word boundary at ${index}`);
    }
    if (index + 1 === header.wordCount && views.deleteKeyOffsets[0] !== terminator + 1) {
      throw new Error('delete key pool does not follow word pool');
    }
  }

  const deleteBytesAt = index => {
    const start = views.deleteKeyOffsets[index];
    const end = views.deleteKeyOffsets[index + 1];
    return pool.subarray(start, end - 1);
  };
  for (let index = 1; index < views.sortedWordIdx.length; index++) {
    const previous = wordBytesAt(views.sortedWordIdx[index - 1]);
    const current = wordBytesAt(views.sortedWordIdx[index]);
    if (Buffer.compare(previous, current) > 0) {
      throw new Error('sortedWordIdx is not sorted by UTF-8 byte order');
    }
  }
  for (let index = 1; index < views.deleteKeyOffsets.length - 1; index++) {
    const previous = deleteBytesAt(index - 1);
    const current = deleteBytesAt(index);
    if (Buffer.compare(previous, current) > 0) {
      throw new Error('delete keys are not sorted by UTF-8 byte order');
    }
  }
}

function normalizeBlobOptions(options) {
  return options ? { ...options } : {};
}

function prepareBlob(symspell, options) {
  if (!symspell || !Array.isArray(symspell.words) || !Array.isArray(symspell.counts)
      || !Array.isArray(symspell.deleteKeys) || !Array.isArray(symspell.deleteOffsets)
      || !Array.isArray(symspell.deleteValues)) {
    throw new TypeError('buildSymSpellBlob expects a finalized SymSpell instance');
  }
  if (!symspell.isFinalized) {
    symspell.finalize();
  }

  const lang = normalizeLanguage(options.lang);
  const maxEditDistance = options.maxEditDistance ?? SYMSPELL_MAX_EDIT_DISTANCE;
  const prefixLength = options.prefixLength ?? SYMSPELL_PREFIX_LENGTH;
  if (maxEditDistance !== SYMSPELL_MAX_EDIT_DISTANCE || prefixLength !== SYMSPELL_PREFIX_LENGTH) {
    throw new Error('SymSpell blob v1 requires maxEditDistance=2 and prefixLength=7');
  }
  if (symspell.maxEditDistance !== maxEditDistance || symspell.prefixLength !== prefixLength) {
    throw new Error('SymSpell instance configuration does not match blob v1');
  }

  const wordBytes = symspell.words.map(word => Buffer.from(word, 'utf8'));
  const deleteKeyBytes = symspell.deleteKeys.map(key => Buffer.from(key, 'utf8'));
  if (wordBytes.length === 0 || deleteKeyBytes.length === 0 || symspell.deleteValues.length === 0) {
    throw new Error('SymSpell blob dimensions must be non-zero');
  }
  const sortedWordIdx = Array.from({ length: symspell.words.length }, (_, index) => index)
    .sort((a, b) => Buffer.compare(wordBytes[a], wordBytes[b]) || a - b);
  const sortedDeleteIdx = Array.from({ length: symspell.deleteKeys.length }, (_, index) => index)
    .sort((a, b) => Buffer.compare(deleteKeyBytes[a], deleteKeyBytes[b]) || a - b);

  const wordOffsets = new Uint32Array(symspell.words.length + 1);
  const deleteKeyOffsets = new Uint32Array(symspell.deleteKeys.length + 1);
  const wordPoolBytes = wordBytes.reduce((total, bytes) => total + bytes.length + 1, 0);
  const deleteKeyPoolBytes = deleteKeyBytes.reduce((total, bytes) => total + bytes.length + 1, 0);
  const stringPoolBytes = wordPoolBytes + deleteKeyPoolBytes;
  assertUint32(stringPoolBytes, 'stringPoolBytes');

  const stringPool = Buffer.alloc(stringPoolBytes);
  let poolOffset = 0;
  for (let index = 0; index < wordBytes.length; index++) {
    wordOffsets[index] = poolOffset;
    wordBytes[index].copy(stringPool, poolOffset);
    poolOffset += wordBytes[index].length;
    stringPool[poolOffset++] = 0;
  }
  for (let sortedIndex = 0; sortedIndex < sortedDeleteIdx.length; sortedIndex++) {
    const originalIndex = sortedDeleteIdx[sortedIndex];
    deleteKeyOffsets[sortedIndex] = poolOffset;
    deleteKeyBytes[originalIndex].copy(stringPool, poolOffset);
    poolOffset += deleteKeyBytes[originalIndex].length;
    stringPool[poolOffset++] = 0;
  }
  wordOffsets[wordBytes.length] = stringPoolBytes;
  deleteKeyOffsets[sortedDeleteIdx.length] = poolOffset;

  const deleteOffsets = new Int32Array(sortedDeleteIdx.length + 1);
  const deleteValues = new Int32Array(symspell.deleteValues.length);
  let deleteValueOffset = 0;
  for (let sortedIndex = 0; sortedIndex < sortedDeleteIdx.length; sortedIndex++) {
    const originalIndex = sortedDeleteIdx[sortedIndex];
    deleteOffsets[sortedIndex] = deleteValueOffset;
    const start = symspell.deleteOffsets[originalIndex];
    const end = symspell.deleteOffsets[originalIndex + 1];
    for (let valueIndex = start; valueIndex < end; valueIndex++) {
      const wordIndex = symspell.deleteValues[valueIndex];
      assertNonNegativeInt32(wordIndex, 'delete value');
      deleteValues[deleteValueOffset++] = wordIndex;
    }
  }
  deleteOffsets[sortedDeleteIdx.length] = deleteValueOffset;

  if (deleteKeyOffsets[0] !== wordPoolBytes
      || wordOffsets[wordOffsets.length - 1] !== stringPoolBytes
      || deleteKeyOffsets[deleteKeyOffsets.length - 1] !== stringPoolBytes) {
    throw new Error('SymSpell string pool size calculation mismatch');
  }
  assertUint32(symspell.words.length, 'wordCount');
  assertUint32(symspell.deleteKeys.length, 'deleteKeyCount');
  assertUint32(deleteValues.length, 'deleteValueCount');
  for (const count of symspell.counts) {
    assertInt32(count, 'word frequency');
  }
  if (symspell.counts.length !== symspell.words.length
      || deleteValueOffset !== symspell.deleteValues.length) {
    throw new Error('SymSpell dimensions are inconsistent');
  }

  const header = {
    magic: SYMSPELL_BLOB_MAGIC,
    formatVersion: SYMSPELL_BLOB_FORMAT_VERSION,
    maxEditDistance,
    prefixLength,
    lang,
    wordCount: symspell.words.length,
    deleteKeyCount: symspell.deleteKeys.length,
    deleteValueCount: deleteValues.length,
    stringPoolBytes,
    wordlistFnv1a64: options.wordlistFnv1a64 === undefined
      ? 0n
      : BigInt(options.wordlistFnv1a64),
  };
  const layout = computeLayout(header);
  const blob = Buffer.alloc(layout.fileSize);

  blob.write(SYMSPELL_BLOB_MAGIC, 0, 4, 'ascii');
  blob.writeUInt16LE(SYMSPELL_BLOB_FORMAT_VERSION, 4);
  blob.writeUInt8(maxEditDistance, 6);
  blob.writeUInt8(prefixLength, 7);
  languageBytes(lang).copy(blob, 8);
  blob.writeUInt32LE(header.wordCount, 0x0c);
  blob.writeUInt32LE(header.deleteKeyCount, 0x10);
  blob.writeUInt32LE(header.deleteValueCount, 0x14);
  blob.writeUInt32LE(header.stringPoolBytes, 0x18);
  blob.writeBigUInt64LE(header.wordlistFnv1a64 & FNV1A64_MASK, 0x1c);

  for (let index = 0; index < wordOffsets.length; index++) {
    blob.writeUInt32LE(wordOffsets[index], layout.wordOffsets.offset + index * 4);
  }
  for (let index = 0; index < sortedWordIdx.length; index++) {
    blob.writeUInt32LE(sortedWordIdx[index], layout.sortedWordIdx.offset + index * 4);
  }
  for (let index = 0; index < symspell.counts.length; index++) {
    blob.writeInt32LE(symspell.counts[index], layout.counts.offset + index * 4);
  }
  for (let index = 0; index < deleteKeyOffsets.length; index++) {
    blob.writeUInt32LE(deleteKeyOffsets[index], layout.deleteKeyOffsets.offset + index * 4);
  }
  for (let index = 0; index < deleteOffsets.length; index++) {
    blob.writeInt32LE(deleteOffsets[index], layout.deleteOffsets.offset + index * 4);
  }
  for (let index = 0; index < deleteValues.length; index++) {
    blob.writeInt32LE(deleteValues[index], layout.deleteValues.offset + index * 4);
  }
  stringPool.copy(blob, layout.stringPool.offset);

  const blobHash = fnv1a64(blob.subarray(0, layout.blobFnv1a64));
  blob.writeBigUInt64LE(blobHash, layout.blobFnv1a64);
  return blob;
}

/**
 * Serializes a finalized SymSpell instance to a v1 blob.
 * @param {SymSpell|Array<{word:string,count:number}>} symspellOrEntries
 * @param {{lang:string,maxEditDistance?:number,prefixLength?:number,wordlistFnv1a64?:bigint}} options
 * @returns {Buffer}
 */
export function buildSymSpellBlob(symspellOrEntries, options = {}) {
  let symspell = symspellOrEntries;
  const normalizedOptions = normalizeBlobOptions(options);

  if (Array.isArray(symspellOrEntries)) {
    const maxEditDistance = normalizedOptions.maxEditDistance ?? SYMSPELL_MAX_EDIT_DISTANCE;
    const prefixLength = normalizedOptions.prefixLength ?? SYMSPELL_PREFIX_LENGTH;
    symspell = new SymSpell(maxEditDistance, prefixLength);
    symspell.bulkLoad(symspellOrEntries);
  } else if (symspellOrEntries && symspellOrEntries.symspell instanceof SymSpell) {
    symspell = symspellOrEntries.symspell;
    Object.assign(normalizedOptions, symspellOrEntries);
  }

  return prepareBlob(symspell, normalizedOptions);
}

/**
 * Writes a v1 blob and returns the exact bytes written.
 * @param {string} filePath
 * @param {SymSpell|Array<{word:string,count:number}>} symspellOrEntries
 * @param {object} options
 * @returns {Buffer}
 */
export function writeSymSpellBlob(filePath, symspellOrEntries, options = {}) {
  const blob = buildSymSpellBlob(symspellOrEntries, options);
  fs.writeFileSync(filePath, blob);
  return blob;
}

function checkedIndex(index, length, name) {
  if (!Number.isInteger(index) || index < 0 || index >= length) {
    throw new RangeError(`${name} index out of range: ${index}`);
  }
}

/**
 * Reads and validates a v1 blob, returning pooled accessors and typed arrays.
 * @param {string|Buffer|Uint8Array} pathOrBuffer
 * @param {object|string} [options]
 * @returns {object}
 */
export function readSymSpellBlob(pathOrBuffer, options) {
  const normalizedOptions = normalizeReadOptions(pathOrBuffer, options);
  const data = readInput(pathOrBuffer);
  const header = parseHeader(data);
  validateHeader(header, normalizedOptions);
  const layout = computeLayout(header);

  if (layout.fileSize !== data.length) {
    throw new Error(`invalid SymSpell blob dimensions: expected ${layout.fileSize} bytes, got ${data.length}`);
  }
  if (layout.sectionEnd !== data.length - 8) {
    throw new Error('SymSpell blob section end does not match checksum position');
  }
  if (data.readBigUInt64LE(layout.blobFnv1a64) !== fnv1a64(data.subarray(0, layout.blobFnv1a64))) {
    throw new Error('SymSpell blob checksum mismatch');
  }
  for (const byte of data.subarray(layout.stringPool.offset + header.stringPoolBytes, layout.blobFnv1a64)) {
    if (byte !== 0) {
      throw new Error('non-zero SymSpell blob alignment padding');
    }
  }
  if (header.reserved.some(byte => byte !== 0)) {
    throw new Error('non-zero SymSpell blob reserved header bytes');
  }

  const views = {
    wordOffsets: readUint32Array(data, layout.wordOffsets.offset, header.wordCount + 1),
    sortedWordIdx: readUint32Array(data, layout.sortedWordIdx.offset, header.wordCount),
    counts: readInt32Array(data, layout.counts.offset, header.wordCount),
    deleteKeyOffsets: readUint32Array(data, layout.deleteKeyOffsets.offset, header.deleteKeyCount + 1),
    deleteOffsets: readInt32Array(data, layout.deleteOffsets.offset, header.deleteKeyCount + 1),
    deleteValues: readInt32Array(data, layout.deleteValues.offset, header.deleteValueCount),
  };
  validateOffsets(data, layout, header, views);

  const stringPool = data.subarray(layout.stringPool.offset, layout.stringPool.offset + header.stringPoolBytes);
  const pooledWordBytesAt = index => {
    const end = stringPool.indexOf(0, views.wordOffsets[index]);
    return stringPool.subarray(views.wordOffsets[index], end);
  };
  const pooledDeleteKeyBytesAt = index => stringPool.subarray(
    views.deleteKeyOffsets[index],
    views.deleteKeyOffsets[index + 1] - 1
  );

  const findWordIndex = word => {
    const query = Buffer.from(word, 'utf8');
    let low = 0;
    let high = views.sortedWordIdx.length - 1;
    while (low <= high) {
      const middle = (low + high) >> 1;
      const wordIndex = views.sortedWordIdx[middle];
      const comparison = Buffer.compare(pooledWordBytesAt(wordIndex), query);
      if (comparison === 0) return wordIndex;
      if (comparison < 0) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return -1;
  };

  const findDeleteKeyIndex = key => {
    const query = Buffer.from(key, 'utf8');
    let low = 0;
    let high = header.deleteKeyCount - 1;
    while (low <= high) {
      const middle = (low + high) >> 1;
      const comparison = Buffer.compare(pooledDeleteKeyBytesAt(middle), query);
      if (comparison === 0) return middle;
      if (comparison < 0) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return -1;
  };

  const editGenerator = new SymSpell(header.maxEditDistance, header.prefixLength);
  const blob = {
    buffer: data,
    header: { ...header },
    magic: header.magic,
    formatVersion: header.formatVersion,
    maxEditDistance: header.maxEditDistance,
    prefixLength: header.prefixLength,
    lang: header.lang,
    language: header.lang,
    wordCount: header.wordCount,
    deleteKeyCount: header.deleteKeyCount,
    deleteValueCount: header.deleteValueCount,
    stringPoolBytes: header.stringPoolBytes,
    wordlistFnv1a64: header.wordlistFnv1a64,
    blobFnv1a64: data.readBigUInt64LE(layout.blobFnv1a64),
    wordOffsets: views.wordOffsets,
    sortedWordIdx: views.sortedWordIdx,
    counts: views.counts,
    deleteKeyOffsets: views.deleteKeyOffsets,
    deleteOffsets: views.deleteOffsets,
    deleteValues: views.deleteValues,
    stringPool,
    sectionOffsets: {
      wordOffsets: layout.wordOffsets.offset,
      sortedWordIdx: layout.sortedWordIdx.offset,
      counts: layout.counts.offset,
      deleteKeyOffsets: layout.deleteKeyOffsets.offset,
      deleteOffsets: layout.deleteOffsets.offset,
      deleteValues: layout.deleteValues.offset,
      stringPool: layout.stringPool.offset,
      blobFnv1a64: layout.blobFnv1a64,
      fileSize: layout.fileSize,
    },
    wordBytesAt(index) {
      checkedIndex(index, header.wordCount, 'word');
      return pooledWordBytesAt(index);
    },
    wordAt(index) {
      return this.wordBytesAt(index).toString('utf8');
    },
    getWord(index) {
      return this.wordAt(index);
    },
    deleteKeyBytesAt(index) {
      checkedIndex(index, header.deleteKeyCount, 'delete key');
      return pooledDeleteKeyBytesAt(index);
    },
    deleteKeyAt(index) {
      return this.deleteKeyBytesAt(index).toString('utf8');
    },
    getDeleteKey(index) {
      return this.deleteKeyAt(index);
    },
    countFor(word) {
      const index = findWordIndex(word);
      return index === -1 ? 0 : views.counts[index];
    },
    lookup(input, editDistance, verbosity = 'top') {
      const maxED = editDistance ?? header.maxEditDistance;
      const inputLower = input.toLowerCase();
      const suggestionSet = new Map();

      const exactIndex = findWordIndex(inputLower);
      if (exactIndex !== -1) {
        suggestionSet.set(inputLower, {
          count: views.counts[exactIndex],
          distance: 0,
        });
      }

      const inputPrefix = inputLower.slice(0, header.prefixLength);
      const inputDeletes = editGenerator._edits(inputPrefix, maxED);
      for (const deleteKey of inputDeletes) {
        const deleteIndex = findDeleteKeyIndex(deleteKey);
        if (deleteIndex === -1) continue;

        const start = views.deleteOffsets[deleteIndex];
        const end = views.deleteOffsets[deleteIndex + 1];
        for (let valueIndex = start; valueIndex < end; valueIndex++) {
          const wordIndex = views.deleteValues[valueIndex];
          const word = pooledWordBytesAt(wordIndex).toString('utf8');
          if (suggestionSet.has(word)) continue;

          const distance = levenshteinDistance(inputLower, word);
          if (distance <= maxED) {
            suggestionSet.set(word, {
              count: views.counts[wordIndex],
              distance,
            });
          }
        }
      }

      const sorted = [...suggestionSet.entries()]
        .map(([term, value]) => ({ term, count: value.count, distance: value.distance }))
        .sort((a, b) => {
          if (a.distance !== b.distance) return a.distance - b.distance;
          return b.count - a.count;
        });

      switch (verbosity) {
        case 'top':
          return sorted.slice(0, 1);
        case 'all':
        case 'closest':
          return sorted;
        default:
          return sorted;
      }
    },
  };

  return blob;
}
