import { inflateSync } from 'node:zlib';

export const MAX_IMAGE_BYTES = 20 * 1024 * 1024;
export const SPRITE_LAYOUTS = Object.freeze({
  'pets-v1': { width: 1536, height: 1872, cellWidth: 192, cellHeight: 208 },
  'pets-v2': { width: 1536, height: 2288, cellWidth: 192, cellHeight: 208 },
});
const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const crcTable = Array.from({ length: 256 }, (_, n) => {
  for (let k = 0; k < 8; k++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n >>> 0;
});
export function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

// Validate the full PNG structure and decompressed scanlines, not only its header.
export function validateSpritePNG(base64, layout) {
  const expected = SPRITE_LAYOUTS[layout];
  if (!expected) throw new TypeError('알 수 없는 Pets 스프라이트 규격입니다.');
  if (typeof base64 !== 'string' || !base64.length || base64.length > Math.ceil(MAX_IMAGE_BYTES / 3) * 4
    || base64.length % 4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(base64)) {
    throw new TypeError('PNG는 20 MiB 이하의 올바른 base64여야 합니다.');
  }
  const bytes = Buffer.from(base64, 'base64');
  if (bytes.length > MAX_IMAGE_BYTES || bytes.toString('base64') !== base64 || !bytes.subarray(0, 8).equals(signature)) {
    throw new TypeError('올바른 PNG 파일이 아닙니다.');
  }
  let offset = 8, header, ended = false, hasPalette = false, idatEnded = false;
  const compressed = [];
  while (offset < bytes.length) {
    if (offset + 12 > bytes.length) throw new TypeError('PNG 청크가 잘렸습니다.');
    const length = bytes.readUInt32BE(offset);
    if (length > bytes.length - offset - 12) throw new TypeError('PNG 청크 길이가 잘못되었습니다.');
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    const payload = bytes.subarray(offset + 8, offset + 8 + length);
    if (crc32(bytes.subarray(offset + 4, offset + 8 + length)) !== bytes.readUInt32BE(offset + 8 + length)) {
      throw new TypeError('PNG 체크섬이 일치하지 않습니다.');
    }
    if (!header && type !== 'IHDR') throw new TypeError('PNG 헤더가 없습니다.');
    if (type === 'IHDR') {
      if (header || length !== 13) throw new TypeError('PNG 헤더가 잘못되었습니다.');
      header = { width: payload.readUInt32BE(0), height: payload.readUInt32BE(4), depth: payload[8], color: payload[9], interlace: payload[12] };
      if (header.width !== expected.width || header.height !== expected.height) {
        throw new TypeError(`${layout}는 ${expected.width} × ${expected.height} PNG가 필요합니다.`);
      }
      const validDepths = { 0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16] };
      if (!validDepths[header.color]?.includes(header.depth) || payload[10] || payload[11] || header.interlace > 1) {
        throw new TypeError('지원되지 않는 PNG 인코딩입니다.');
      }
    } else if (type === 'IDAT') {
      if (idatEnded) throw new TypeError('PNG 이미지 청크 순서가 잘못되었습니다.');
      compressed.push(payload);
    } else if (type === 'PLTE') {
      if (compressed.length || !length || length % 3 || length > 768) throw new TypeError('PNG 팔레트가 잘못되었습니다.');
      hasPalette = true;
    } else if (type === 'IEND') {
      if (length !== 0 || offset + 12 !== bytes.length) throw new TypeError('PNG 끝부분이 잘못되었습니다.');
      ended = true;
      offset += 12;
      break;
    } else {
      if (!/^[A-Za-z]{4}$/.test(type) || /^[A-Z]/.test(type)) throw new TypeError('알 수 없는 PNG 필수 청크입니다.');
      if (compressed.length) idatEnded = true;
    }
    offset += length + 12;
  }
  if (!ended || !compressed.length || (header.color === 3 && !hasPalette)) throw new TypeError('PNG 이미지 데이터가 없습니다.');
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[header.color];
  const passes = header.interlace ? [[0,0,8,8],[4,0,8,8],[0,4,4,8],[2,0,4,4],[0,2,2,4],[1,0,2,2],[0,1,1,2]] : [[0,0,1,1]];
  const rows = [];
  for (const [x, y, dx, dy] of passes) {
    const width = Math.ceil((header.width - x) / dx), height = Math.ceil((header.height - y) / dy);
    if (width > 0 && height > 0) for (let row = 0; row < height; row++) rows.push(Math.ceil(width * channels * header.depth / 8));
  }
  const outputLength = rows.reduce((sum, row) => sum + row + 1, 0);
  let decoded;
  try { decoded = inflateSync(Buffer.concat(compressed), { maxOutputLength: outputLength }); }
  catch { throw new TypeError('PNG 압축 이미지 데이터가 손상되었습니다.'); }
  if (decoded.length !== outputLength) throw new TypeError('PNG 이미지 데이터 길이가 잘못되었습니다.');
  let cursor = 0;
  for (const row of rows) {
    if (decoded[cursor] > 4) throw new TypeError('PNG 필터가 잘못되었습니다.');
    cursor += row + 1;
  }
  return { ...expected, byteLength: bytes.length };
}
