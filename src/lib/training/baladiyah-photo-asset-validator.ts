import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { baladiyahDraftCurriculum, trainingLocales } from "./baladiyah-draft-curriculum.js";
import {
  baladiyahPhotoAssetManifest,
  expectedBaladiyahPhotoAssetCount,
  photoApprovalStatuses,
  type BaladiyahPhotoAsset,
} from "./baladiyah-photo-asset-manifest.js";

export type PhotoAssetValidationIssue = {
  severity: "warning" | "error";
  code: string;
  asset_key?: string;
  message: string;
};

export type PhotoAssetValidationResult = {
  mode: "draft" | "strict";
  asset_count: number;
  approved_count: number;
  missing_file_count: number;
  issues: PhotoAssetValidationIssue[];
  valid: boolean;
};

const allowedPath = /^\/training\/baladiyah\/[a-z0-9]+(?:-[a-z0-9]+)*\/(?:overview|practical-\d{2}|step-\d{2}|comparison-\d{2}|warning-\d{2}|reference-\d{2})\.webp$/u;
const sha256Pattern = /^[a-f0-9]{64}$/u;
const obsoleteCompositePaths = new Set([
  "/training/baladiyah/personal-hygiene-health/practical-01.webp",
  "/training/baladiyah/cleaning-sanitation/practical-01.webp",
]);

export function validateBaladiyahPhotoAssets(options: {
  publicRoot: string;
  strict?: boolean;
  assets?: readonly BaladiyahPhotoAsset[];
}): PhotoAssetValidationResult {
  const strict = Boolean(options.strict);
  const assets = options.assets ?? baladiyahPhotoAssetManifest;
  const issues: PhotoAssetValidationIssue[] = [];
  const issue = (severity: "warning" | "error", code: string, message: string, asset_key?: string) => {
    issues.push({ severity, code, message, ...(asset_key ? { asset_key } : {}) });
  };
  const draftSeverity = strict ? "error" : "warning";
  const seenKeys = new Set<string>();
  const seenPaths = new Set<string>();
  let missingFileCount = 0;

  const curriculumModules = new Map(baladiyahDraftCurriculum.modules.map((module) => [module.stable_key, module]));
  const requiredKeys = new Set(
    baladiyahDraftCurriculum.modules.flatMap((module) => module.metadata.photo_requirements.map((photo) => photo.asset_key)),
  );

  if (assets.length !== expectedBaladiyahPhotoAssetCount) {
    issue("error", "asset_count_mismatch", `Expected ${expectedBaladiyahPhotoAssetCount} assets; received ${assets.length}.`);
  }

  for (const asset of assets) {
    if (seenKeys.has(asset.asset_key)) issue("error", "duplicate_asset_key", `Duplicate asset key ${asset.asset_key}.`, asset.asset_key);
    seenKeys.add(asset.asset_key);
    if (seenPaths.has(asset.src)) issue("error", "duplicate_asset_path", `Duplicate asset path ${asset.src}.`, asset.asset_key);
    seenPaths.add(asset.src);

    if (!requiredKeys.has(asset.asset_key)) issue("error", "unknown_asset_key", "Asset is not required by the draft curriculum.", asset.asset_key);
    if (obsoleteCompositePaths.has(asset.src)) issue("error", "obsolete_composite_path", "Procedural composite images are no longer allowed.", asset.asset_key);
    if (!allowedPath.test(asset.src)) issue("error", "invalid_asset_path", `Path is outside the Baladiyah WebP allowlist: ${asset.src}`, asset.asset_key);
    if (!asset.src.startsWith(`/training/baladiyah/${asset.module_key}/`)) issue("error", "module_path_mismatch", "Asset path does not match module_key.", asset.asset_key);
    if (!asset.src.endsWith(".webp")) issue("error", "invalid_format", "Asset path must use the .webp extension.", asset.asset_key);
    if (!photoApprovalStatuses.includes(asset.approval_status)) issue("error", "invalid_approval_status", `Unknown approval status ${asset.approval_status}.`, asset.asset_key);

    for (const locale of trainingLocales) {
      if (!asset.alt_i18n[locale]?.trim()) issue("error", "missing_alt_text", `Missing ${locale} alt text.`, asset.asset_key);
    }

    const module = curriculumModules.get(asset.module_key);
    if (!module) {
      issue("error", "unknown_module", `Unknown module ${asset.module_key}.`, asset.asset_key);
    } else {
      const knownFacts = new Set(module.metadata.provenance_facts.map((fact) => fact.fact_key));
      if (!asset.provenance.source_fact_keys.length) issue("error", "missing_provenance", "At least one source fact is required.", asset.asset_key);
      for (const factKey of asset.provenance.source_fact_keys) {
        if (!knownFacts.has(factKey)) issue("error", "unknown_source_fact", `Unknown source fact ${factKey}.`, asset.asset_key);
      }
    }

    const dimensionsComplete = Number.isInteger(asset.width) && Number.isInteger(asset.height) && Number(asset.width) > 0 && Number(asset.height) > 0;
    if (!dimensionsComplete) issue(draftSeverity, "dimensions_pending", "Intrinsic width and height are required before approval.", asset.asset_key);
    if (!asset.sha256 || !sha256Pattern.test(asset.sha256)) issue(draftSeverity, "sha256_pending", "A lowercase SHA-256 is required before approval.", asset.asset_key);
    if (asset.approval_status !== "approved") issue(draftSeverity, "approval_pending", `Approval status is ${asset.approval_status}.`, asset.asset_key);

    const filePath = path.join(options.publicRoot, asset.src.slice(1));
    if (!existsSync(filePath)) {
      missingFileCount += 1;
      issue(draftSeverity, "file_missing", `Asset file is not present at ${filePath}.`, asset.asset_key);
      continue;
    }

    const bytes = readFileSync(filePath);
    const webp = inspectWebp(bytes);
    if (!webp) {
      issue("error", "invalid_webp", "File is not a supported WebP image.", asset.asset_key);
      continue;
    }
    if (webp.hasExif) issue("error", "exif_present", "WebP EXIF metadata must be stripped.", asset.asset_key);
    if (webp.width < 1280 || webp.height < 720) issue("error", "resolution_too_small", `File is ${webp.width}x${webp.height}; minimum is 1280x720.`, asset.asset_key);
    if (dimensionsComplete && (webp.width !== asset.width || webp.height !== asset.height)) {
      issue("error", "dimension_mismatch", `Manifest is ${asset.width}x${asset.height}; file is ${webp.width}x${webp.height}.`, asset.asset_key);
    }
    const digest = createHash("sha256").update(bytes).digest("hex");
    if (asset.sha256 && digest !== asset.sha256) issue("error", "sha256_mismatch", "File checksum does not match the manifest.", asset.asset_key);
  }

  for (const requiredKey of requiredKeys) {
    if (!seenKeys.has(requiredKey)) issue("error", "missing_manifest_entry", `No asset manifest entry exists for ${requiredKey}.`, requiredKey);
  }

  const procedureSteps = baladiyahDraftCurriculum.modules.flatMap((module) => {
    const practicalLesson = module.lessons.find((lesson) => lesson.stable_key === "practical-photo-guide");
    const content = practicalLesson?.content_i18n.en as
      | { items?: Array<{ fact_key: string; presentation: string; image?: { asset_key: string; src: string } }> }
      | undefined;
    return (content?.items ?? [])
      .filter((item) => item.presentation === "step")
      .map((item) => ({ module_key: module.stable_key, ...item }));
  });
  const mappedProcedureAssetKeys = new Set<string>();

  for (const step of procedureSteps) {
    const matches = assets.filter(
      (asset) => asset.module_key === step.module_key
        && asset.visual_kind === "procedure"
        && asset.provenance.source_fact_keys.includes(step.fact_key),
    );
    if (matches.length !== 1) {
      issue("error", "procedure_step_asset_count", `Procedural fact ${step.fact_key} must map to exactly one asset.`);
      continue;
    }
    const [asset] = matches;
    if (mappedProcedureAssetKeys.has(asset.asset_key)) {
      issue("error", "procedure_asset_reused", `Procedural asset ${asset.asset_key} is mapped to more than one step.`, asset.asset_key);
    }
    mappedProcedureAssetKeys.add(asset.asset_key);
    if (asset.provenance.source_fact_keys.length !== 1) {
      issue("error", "procedure_asset_fact_count", "Each procedural asset must reference exactly one step fact.", asset.asset_key);
    }
    if (!step.image || step.image.asset_key !== asset.asset_key || step.image.src !== asset.src) {
      issue("error", "procedure_step_mapping_mismatch", `Procedural fact ${step.fact_key} does not match its learner image reference.`, asset.asset_key);
    }
    if (asset.placement !== "procedure-step" || asset.visual_kind !== "procedure") {
      issue("error", "procedure_step_contract", "Procedural assets must use procedure-step placement and procedure visual kind.", asset.asset_key);
    }
  }

  return {
    mode: strict ? "strict" : "draft",
    asset_count: assets.length,
    approved_count: assets.filter((asset) => asset.approval_status === "approved").length,
    missing_file_count: missingFileCount,
    issues,
    valid: !issues.some((entry) => entry.severity === "error"),
  };
}

function inspectWebp(bytes: Buffer): { width: number; height: number; hasExif: boolean } | null {
  if (bytes.length < 30 || bytes.toString("ascii", 0, 4) !== "RIFF" || bytes.toString("ascii", 8, 12) !== "WEBP") return null;

  let offset = 12;
  let dimensions: { width: number; height: number } | null = null;
  let hasExif = false;
  while (offset + 8 <= bytes.length) {
    const chunk = bytes.toString("ascii", offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    const data = offset + 8;
    if (data + size > bytes.length) return null;

    if (chunk === "EXIF") hasExif = true;
    if (!dimensions && chunk === "VP8X" && size >= 10) {
      dimensions = { width: bytes.readUIntLE(data + 4, 3) + 1, height: bytes.readUIntLE(data + 7, 3) + 1 };
    } else if (!dimensions && chunk === "VP8L" && size >= 5 && bytes[data] === 0x2f) {
      const b0 = bytes[data + 1] ?? 0;
      const b1 = bytes[data + 2] ?? 0;
      const b2 = bytes[data + 3] ?? 0;
      const b3 = bytes[data + 4] ?? 0;
      dimensions = { width: 1 + b0 + ((b1 & 0x3f) << 8), height: 1 + (b1 >> 6) + (b2 << 2) + ((b3 & 0x0f) << 10) };
    } else if (!dimensions && chunk === "VP8 " && size >= 10 && bytes[data + 3] === 0x9d && bytes[data + 4] === 0x01 && bytes[data + 5] === 0x2a) {
      dimensions = { width: bytes.readUInt16LE(data + 6) & 0x3fff, height: bytes.readUInt16LE(data + 8) & 0x3fff };
    }

    offset = data + size + (size % 2);
  }
  return dimensions ? { ...dimensions, hasExif } : null;
}
