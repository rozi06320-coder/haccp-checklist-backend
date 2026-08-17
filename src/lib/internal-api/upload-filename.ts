import { TextDecoder } from "node:util";

export const MAX_UPLOAD_FILENAME_LENGTH = 180;

const base64UrlPattern = /^[A-Za-z0-9_-]+$/u;
const controlCharacterPattern = /[\u0000-\u001f\u007f]/u;

export function encodeUploadFilename(value: string) {
  return Buffer.from(value, "utf8").toString("base64url");
}

export function decodeUploadFilename(value: string | undefined) {
  if (!value || value.length > 1024 || !base64UrlPattern.test(value)) return null;
  try {
    const bytes = Buffer.from(value, "base64url");
    if (!bytes.length || bytes.toString("base64url") !== value) return null;
    const filename = new TextDecoder("utf-8", { fatal: true }).decode(bytes).trim();
    if (!filename || [...filename].length > MAX_UPLOAD_FILENAME_LENGTH || controlCharacterPattern.test(filename)) return null;
    return filename;
  } catch {
    return null;
  }
}
