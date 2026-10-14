import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { baladiyahDraftCurriculum, trainingLocales } from "../lib/training/baladiyah-draft-curriculum.js";
import {
  baladiyahPhotoAssetManifest,
  baladiyahPhotoAssetManifestSchema,
  expectedBaladiyahPhotoAssetCount,
  type BaladiyahPhotoAsset,
} from "../lib/training/baladiyah-photo-asset-manifest.js";
import { validateBaladiyahPhotoAssets } from "../lib/training/baladiyah-photo-asset-validator.js";

describe("Baladiyah Phase B3 photo asset plan", () => {
  it("maps all 40 draft requirements exactly once to deterministic local WebP paths", () => {
    const required = baladiyahDraftCurriculum.modules.flatMap((module) =>
      module.metadata.photo_requirements.map((photo) => photo.asset_key),
    );
    assert.equal(required.length, expectedBaladiyahPhotoAssetCount);
    assert.equal(baladiyahPhotoAssetManifest.length, expectedBaladiyahPhotoAssetCount);
    assert.deepEqual([...new Set(baladiyahPhotoAssetManifest.map((asset) => asset.asset_key))].sort(), [...required].sort());
    assert.equal(new Set(baladiyahPhotoAssetManifest.map((asset) => asset.src)).size, expectedBaladiyahPhotoAssetCount);
    for (const asset of baladiyahPhotoAssetManifest) {
      assert.match(asset.src, /^\/training\/baladiyah\/[a-z0-9-]+\/[a-z0-9-]+\.webp$/u);
      assert.equal(asset.src.includes("://"), false);
      assert.equal(asset.approval_status, "needed");
      assert.equal(asset.width, null);
      assert.equal(asset.height, null);
      assert.equal(asset.sha256, null);
    }
  });

  it("keeps exact per-module counts, source provenance, and complete five-language alt text", () => {
    const expectedCounts = new Map([
      ["personal-hygiene-health", 6],
      ["cleaning-sanitation", 7],
      ["contamination-foodborne-illness-prevention", 3],
      ["safe-food-handling", 4],
      ["food-receiving", 4],
      ["storage-temperature-control", 4],
      ["cooking-holding-reheating", 4],
      ["waste-management", 4],
      ["pest-prevention-escalation", 4],
    ]);
    for (const [moduleKey, count] of expectedCounts) {
      assert.equal(baladiyahPhotoAssetManifest.filter((asset) => asset.module_key === moduleKey).length, count);
    }
    for (const asset of baladiyahPhotoAssetManifest) {
      assert.ok(asset.provenance.source_fact_keys.length > 0);
      assert.ok(asset.provenance.provenance_classifications.length > 0);
      assert.deepEqual(Object.keys(asset.alt_i18n).sort(), [...trainingLocales].sort());
      for (const locale of trainingLocales) assert.ok(asset.alt_i18n[locale].trim());
    }
    assert.equal(baladiyahPhotoAssetManifestSchema.target_format, "image/webp");
    assert.equal(baladiyahPhotoAssetManifestSchema.aspect_ratio, "16:9");
  });

  it("replaces both composite images with four distinct, learner-mapped procedure assets", () => {
    const expected = new Map([
      [
        "personal-hygiene-health",
        [
          ["handwash-wet", "personal-hygiene-handwashing-wet", "/training/baladiyah/personal-hygiene-health/step-01.webp"],
          ["handwash-soap", "personal-hygiene-handwashing-soap", "/training/baladiyah/personal-hygiene-health/step-02.webp"],
          ["handwash-scrub", "personal-hygiene-handwashing-scrub", "/training/baladiyah/personal-hygiene-health/step-03.webp"],
          ["handwash-dry", "personal-hygiene-handwashing-dry", "/training/baladiyah/personal-hygiene-health/step-04.webp"],
        ],
      ],
      [
        "cleaning-sanitation",
        [
          ["sink-wash", "cleaning-sanitation-wash", "/training/baladiyah/cleaning-sanitation/step-01.webp"],
          ["sink-rinse", "cleaning-sanitation-rinse", "/training/baladiyah/cleaning-sanitation/step-02.webp"],
          ["sink-sanitize", "cleaning-sanitation-sanitize", "/training/baladiyah/cleaning-sanitation/step-03.webp"],
          ["air-dry", "cleaning-sanitation-air-dry", "/training/baladiyah/cleaning-sanitation/step-04.webp"],
        ],
      ],
    ] as const);

    for (const [moduleKey, mappings] of expected) {
      const module = baladiyahDraftCurriculum.modules.find((candidate) => candidate.stable_key === moduleKey);
      assert.ok(module);
      const lesson = module.lessons.find((candidate) => candidate.stable_key === "practical-photo-guide");
      assert.ok(lesson);
      const content = lesson.content_i18n.en as {
        items: Array<{ fact_key: string; presentation: string; image?: { asset_key: string; src: string } }>;
      };
      const steps = content.items.filter((item) => item.presentation === "step");
      assert.equal(steps.length, 4);

      for (const [factKey, assetKey, src] of mappings) {
        assert.deepEqual(steps.find((step) => step.fact_key === factKey)?.image, { asset_key: assetKey, src });
        const assets = baladiyahPhotoAssetManifest.filter(
          (asset) => asset.module_key === moduleKey
            && asset.visual_kind === "procedure"
            && asset.provenance.source_fact_keys.includes(factKey),
        );
        assert.equal(assets.length, 1);
        assert.equal(assets[0]?.asset_key, assetKey);
        assert.equal(assets[0]?.src, src);
        assert.equal(assets[0]?.placement, "procedure-step");
        assert.equal(assets[0]?.visual_kind, "procedure");
      }
    }

    const serialized = JSON.stringify({ curriculum: baladiyahDraftCurriculum, assets: baladiyahPhotoAssetManifest });
    assert.doesNotMatch(serialized, /personal-hygiene-health\/practical-01\.webp|cleaning-sanitation\/practical-01\.webp/u);
    assert.doesNotMatch(serialized, /personal-hygiene-handwashing-stages|cleaning-four-stage-sequence/u);
  });

  it("maps every procedural curriculum step to exactly one manifest asset", () => {
    for (const module of baladiyahDraftCurriculum.modules) {
      const lesson = module.lessons.find((candidate) => candidate.stable_key === "practical-photo-guide");
      assert.ok(lesson);
      const content = lesson.content_i18n.en as {
        items: Array<{ fact_key: string; presentation: string; image?: { asset_key: string; src: string } }>;
      };
      for (const step of content.items.filter((item) => item.presentation === "step")) {
        assert.ok(step.image);
        const matches = baladiyahPhotoAssetManifest.filter(
          (asset) => asset.module_key === module.stable_key
            && asset.visual_kind === "procedure"
            && asset.provenance.source_fact_keys.includes(step.fact_key),
        );
        assert.equal(matches.length, 1);
        assert.equal(matches[0]?.asset_key, step.image.asset_key);
        assert.equal(matches[0]?.src, step.image.src);
      }
    }
  });

  it("allows missing files and pending approval in draft mode without hiding warnings", () => {
    const result = validateBaladiyahPhotoAssets({ publicRoot: "/path/that/does/not/exist" });
    assert.equal(result.valid, true);
    assert.equal(result.mode, "draft");
    assert.equal(result.asset_count, expectedBaladiyahPhotoAssetCount);
    assert.equal(result.missing_file_count, expectedBaladiyahPhotoAssetCount);
    assert.equal(result.issues.filter((issue) => issue.code === "file_missing").length, expectedBaladiyahPhotoAssetCount);
    assert.equal(result.issues.some((issue) => issue.severity === "error"), false);
  });

  it("makes missing files, metadata, and approval blocking in strict mode", () => {
    const result = validateBaladiyahPhotoAssets({ publicRoot: "/path/that/does/not/exist", strict: true });
    assert.equal(result.valid, false);
    assert.ok(result.issues.some((issue) => issue.code === "file_missing" && issue.severity === "error"));
    assert.ok(result.issues.some((issue) => issue.code === "dimensions_pending" && issue.severity === "error"));
    assert.ok(result.issues.some((issue) => issue.code === "sha256_pending" && issue.severity === "error"));
    assert.ok(result.issues.some((issue) => issue.code === "approval_pending" && issue.severity === "error"));
  });

  it("rejects duplicate keys and paths outside the local asset allowlist in every mode", () => {
    const assets = structuredClone(baladiyahPhotoAssetManifest) as BaladiyahPhotoAsset[];
    assets[1] = { ...assets[1], asset_key: assets[0].asset_key, src: "https://example.com/photo.webp" };
    const result = validateBaladiyahPhotoAssets({ publicRoot: "/path/that/does/not/exist", assets });
    assert.equal(result.valid, false);
    assert.ok(result.issues.some((issue) => issue.code === "duplicate_asset_key"));
    assert.ok(result.issues.some((issue) => issue.code === "invalid_asset_path"));
    assert.ok(result.issues.some((issue) => issue.code === "missing_manifest_entry"));
  });
});
