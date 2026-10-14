import {
  baladiyahDraftCurriculum,
  trainingLocales,
  type LocalizedText,
  type ProvenanceClassification,
} from "./baladiyah-draft-curriculum.js";

export const photoApprovalStatuses = ["needed", "submitted", "approved", "rejected"] as const;
export const expectedBaladiyahPhotoAssetCount = 40;
export type PhotoApprovalStatus = (typeof photoApprovalStatuses)[number];
export type PhotoVisualKind = "overview" | "procedure" | "comparison" | "warning_example" | "reference";

export type BaladiyahPhotoAsset = {
  asset_key: string;
  module_key: string;
  lesson_key: "overview" | "practical-photo-guide";
  placement: string;
  visual_kind: PhotoVisualKind;
  src: string;
  width: number | null;
  height: number | null;
  sha256: string | null;
  alt_i18n: LocalizedText;
  approval_status: PhotoApprovalStatus;
  provenance: {
    source: "baladiyah_draft_curriculum";
    source_module_ids: string[];
    source_fact_keys: string[];
    provenance_classifications: ProvenanceClassification[];
  };
};

type AssetPlan = {
  asset_key: string;
  filename: string;
  visual_kind: PhotoVisualKind;
  source_fact_keys: string[];
};

const assetPlans: AssetPlan[] = [
  { asset_key: "personal-hygiene-clean-uniform-ppe", filename: "overview.webp", visual_kind: "overview", source_fact_keys: ["clean-uniform-grooming"] },
  { asset_key: "personal-hygiene-handwashing-wet", filename: "step-01.webp", visual_kind: "procedure", source_fact_keys: ["handwash-wet"] },
  { asset_key: "personal-hygiene-handwashing-soap", filename: "step-02.webp", visual_kind: "procedure", source_fact_keys: ["handwash-soap"] },
  { asset_key: "personal-hygiene-handwashing-scrub", filename: "step-03.webp", visual_kind: "procedure", source_fact_keys: ["handwash-scrub"] },
  { asset_key: "personal-hygiene-handwashing-dry", filename: "step-04.webp", visual_kind: "procedure", source_fact_keys: ["handwash-dry"] },
  { asset_key: "personal-hygiene-protected-cut", filename: "warning-01.webp", visual_kind: "warning_example", source_fact_keys: ["protected-cut"] },

  { asset_key: "cleaning-food-contact-surface", filename: "overview.webp", visual_kind: "overview", source_fact_keys: ["food-contact-cleaning-frequency"] },
  { asset_key: "cleaning-sanitation-wash", filename: "step-01.webp", visual_kind: "procedure", source_fact_keys: ["sink-wash"] },
  { asset_key: "cleaning-sanitation-rinse", filename: "step-02.webp", visual_kind: "procedure", source_fact_keys: ["sink-rinse"] },
  { asset_key: "cleaning-sanitation-sanitize", filename: "step-03.webp", visual_kind: "procedure", source_fact_keys: ["sink-sanitize"] },
  { asset_key: "cleaning-sanitation-air-dry", filename: "step-04.webp", visual_kind: "procedure", source_fact_keys: ["air-dry"] },
  { asset_key: "cleaning-sanitizer-test", filename: "reference-01.webp", visual_kind: "reference", source_fact_keys: ["sink-sanitize"] },
  { asset_key: "cleaning-color-coded-cloths", filename: "reference-02.webp", visual_kind: "reference", source_fact_keys: ["cloth-colors"] },

  { asset_key: "contamination-raw-rte-separation", filename: "comparison-01.webp", visual_kind: "comparison", source_fact_keys: ["separate-raw-rte"] },
  { asset_key: "contamination-board-colors", filename: "reference-01.webp", visual_kind: "reference", source_fact_keys: ["board-colors"] },
  { asset_key: "contamination-hazard-examples", filename: "warning-01.webp", visual_kind: "warning_example", source_fact_keys: ["biological-hazards", "chemical-hazards", "physical-hazards"] },

  { asset_key: "handling-gloves-handwashing", filename: "overview.webp", visual_kind: "overview", source_fact_keys: ["gloves-not-handwash"] },
  { asset_key: "handling-rte-tools", filename: "reference-01.webp", visual_kind: "reference", source_fact_keys: ["rte-tools"] },
  { asset_key: "handling-cross-contact-comparison", filename: "comparison-01.webp", visual_kind: "comparison", source_fact_keys: ["raw-glove-cross-contact"] },
  { asset_key: "handling-tasting-spoon", filename: "reference-02.webp", visual_kind: "reference", source_fact_keys: ["tasting-spoon"] },

  { asset_key: "receiving-temperature-check", filename: "step-01.webp", visual_kind: "procedure", source_fact_keys: ["receiving-frozen"] },
  { asset_key: "receiving-intact-eggs", filename: "step-02.webp", visual_kind: "procedure", source_fact_keys: ["receiving-chilled"] },
  { asset_key: "receiving-can-comparison", filename: "step-03.webp", visual_kind: "procedure", source_fact_keys: ["receiving-damaged-cans"] },
  { asset_key: "receiving-cold-storage-transfer", filename: "step-04.webp", visual_kind: "procedure", source_fact_keys: ["receiving-transfer-time"] },

  { asset_key: "storage-temperature-log", filename: "overview.webp", visual_kind: "overview", source_fact_keys: ["temperature-log-frequency"] },
  { asset_key: "storage-chiller-hierarchy", filename: "reference-01.webp", visual_kind: "reference", source_fact_keys: ["upper-shelf-rte", "bottom-shelf-poultry"] },
  { asset_key: "storage-shelf-clearance", filename: "reference-02.webp", visual_kind: "reference", source_fact_keys: ["shelf-clearance"] },
  { asset_key: "storage-dry-conditions", filename: "reference-03.webp", visual_kind: "reference", source_fact_keys: ["dry-storage-range"] },

  { asset_key: "cooking-poultry-temperature", filename: "overview.webp", visual_kind: "overview", source_fact_keys: ["poultry-temperature"] },
  { asset_key: "cooking-ground-meat-temperature", filename: "reference-01.webp", visual_kind: "reference", source_fact_keys: ["ground-meat-temperature"] },
  { asset_key: "cooking-holding-comparison", filename: "comparison-01.webp", visual_kind: "comparison", source_fact_keys: ["holding-limits"] },
  { asset_key: "cooking-reheating-reference", filename: "warning-01.webp", visual_kind: "warning_example", source_fact_keys: ["reheating-limit"] },

  { asset_key: "waste-pedal-bin", filename: "overview.webp", visual_kind: "overview", source_fact_keys: ["bin-features", "thick-liner"] },
  { asset_key: "waste-three-quarter-level", filename: "warning-01.webp", visual_kind: "warning_example", source_fact_keys: ["empty-three-quarters"] },
  { asset_key: "waste-covered-dumpster", filename: "reference-01.webp", visual_kind: "reference", source_fact_keys: ["covered-dumpster"] },
  { asset_key: "waste-grease-trap", filename: "reference-02.webp", visual_kind: "reference", source_fact_keys: ["grease-trap-schedule"] },

  { asset_key: "pest-door-gap", filename: "overview.webp", visual_kind: "overview", source_fact_keys: ["rear-door-gap"] },
  { asset_key: "pest-air-curtain", filename: "reference-01.webp", visual_kind: "reference", source_fact_keys: ["air-curtain"] },
  { asset_key: "pest-housekeeping-cardboard", filename: "warning-01.webp", visual_kind: "warning_example", source_fact_keys: ["remove-cardboard"] },
  { asset_key: "pest-evidence", filename: "reference-02.webp", visual_kind: "reference", source_fact_keys: ["pest-signs"] },
];

const modulesByPhotoKey = new Map(
  baladiyahDraftCurriculum.modules.flatMap((module) =>
    module.metadata.photo_requirements.map((requirement) => [requirement.asset_key, { module, requirement }] as const),
  ),
);

export const baladiyahPhotoAssetManifest: readonly BaladiyahPhotoAsset[] = assetPlans.map((plan) => {
  const source = modulesByPhotoKey.get(plan.asset_key);
  if (!source) throw new Error(`Unknown Baladiyah photo requirement: ${plan.asset_key}`);

  const facts = source.module.metadata.provenance_facts.filter((fact) => plan.source_fact_keys.includes(fact.fact_key));
  if (facts.length !== plan.source_fact_keys.length) {
    throw new Error(`Incomplete photo provenance for ${plan.asset_key}`);
  }

  return {
    asset_key: plan.asset_key,
    module_key: source.module.stable_key,
    lesson_key: source.requirement.lesson_key,
    placement: source.requirement.placement,
    visual_kind: plan.visual_kind,
    src: `/training/baladiyah/${source.module.stable_key}/${plan.filename}`,
    width: null,
    height: null,
    sha256: null,
    alt_i18n: { ...source.requirement.alt_i18n },
    approval_status: "needed",
    provenance: {
      source: "baladiyah_draft_curriculum",
      source_module_ids: [...source.module.metadata.source_module_ids],
      source_fact_keys: [...plan.source_fact_keys],
      provenance_classifications: [...new Set(facts.map((fact) => fact.provenance_classification))],
    },
  };
});

export const baladiyahPhotoAssetManifestSchema = {
  schema_version: 1,
  course_key: baladiyahDraftCurriculum.course.course_key,
  version_number: baladiyahDraftCurriculum.course.version_number,
  curriculum_status: baladiyahDraftCurriculum.curriculum_status,
  supported_locales: trainingLocales,
  target_format: "image/webp",
  target_width: 1600,
  target_height: 900,
  minimum_width: 1280,
  minimum_height: 720,
  aspect_ratio: "16:9",
  assets: baladiyahPhotoAssetManifest,
} as const;
