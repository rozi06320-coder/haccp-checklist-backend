import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import {
  baladiyahDraftCurriculum,
  trainingLocales,
} from "../lib/training/baladiyah-draft-curriculum.js";

const migration = readFileSync(
  new URL("../../supabase/migrations/20261014120000_baladiyah_photo_first_draft_curriculum.sql", import.meta.url),
  "utf8",
);

const expectedModuleKeys = [
  "personal-hygiene-health",
  "cleaning-sanitation",
  "contamination-foodborne-illness-prevention",
  "safe-food-handling",
  "food-receiving",
  "storage-temperature-control",
  "cooking-holding-reheating",
  "waste-management",
  "pest-prevention-escalation",
];

const localeKeyPattern = /(?:^|_)(?:title|description|objective|alt|prompt|text|explanation)_i18n$/u;

function visit(value: unknown, path: string[] = []): void {
  if (Array.isArray(value)) {
    value.forEach((item, index) => visit(item, [...path, String(index)]));
    return;
  }
  if (!value || typeof value !== "object") return;

  for (const [key, child] of Object.entries(value)) {
    if (localeKeyPattern.test(key)) {
      assert.ok(child && typeof child === "object" && !Array.isArray(child), `${[...path, key].join(".")} must be a locale object`);
      for (const locale of trainingLocales) {
        const localized = (child as Record<string, unknown>)[locale];
        assert.equal(typeof localized, "string", `${[...path, key, locale].join(".")} must be a string`);
        assert.ok((localized as string).trim().length > 0, `${[...path, key, locale].join(".")} must not be blank`);
      }
    }
    visit(child, [...path, key]);
  }
}

describe("Baladiyah photo-first draft curriculum manifest", () => {
  it("defines the approved draft course identity and exact nine-module taxonomy", () => {
    assert.equal(baladiyahDraftCurriculum.course.course_key, "baladiyah-food-safety-hygiene");
    assert.equal(baladiyahDraftCurriculum.course.version_number, 1);
    assert.equal(baladiyahDraftCurriculum.course.status, "draft");
    assert.deepEqual([...baladiyahDraftCurriculum.course.supported_locales], [...trainingLocales]);
    assert.deepEqual(baladiyahDraftCurriculum.modules.map((module) => module.stable_key), expectedModuleKeys);
    assert.deepEqual(baladiyahDraftCurriculum.modules.map((module) => module.position), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    assert.deepEqual(baladiyahDraftCurriculum.excluded_source_modules, [{
      stable_key: "restaurant-safety",
      disposition: "reserved_for_future_internal_restaurant_safety_course",
      provenance_classification: "internal_operational",
    }]);
  });

  it("contains exactly 27 lessons in the approved three-lesson shape and no video", () => {
    const lessons = baladiyahDraftCurriculum.modules.flatMap((module) => module.lessons);
    assert.equal(lessons.length, 27);
    assert.equal(lessons.filter((lesson) => lesson.lesson_type === "reading").length, 9);
    assert.equal(lessons.filter((lesson) => lesson.lesson_type === "key_points").length, 9);
    assert.equal(lessons.filter((lesson) => lesson.lesson_type === "quiz").length, 9);
    assert.equal(lessons.filter((lesson) => (lesson.lesson_type as string) === "video").length, 0);

    for (const module of baladiyahDraftCurriculum.modules) {
      assert.deepEqual(module.lessons.map((lesson) => lesson.stable_key), ["overview", "practical-photo-guide", "knowledge-check"]);
      assert.deepEqual(module.lessons.map((lesson) => lesson.position), [1, 2, 3]);
      assert.ok(module.lessons.every((lesson) => lesson.minimum_engagement_seconds === 0));
      assert.equal(module.lessons[2]?.pass_threshold_bps, 8000);
    }

    const serialized = JSON.stringify(baladiyahDraftCurriculum);
    assert.doesNotMatch(serialized, /"lesson_type":"video"|"poster"|"playback"|training video/iu);
    assert.doesNotMatch(serialized, /https?:\/\//iu);
    assert.doesNotMatch(serialized, /still applies when the restaurant is busy/iu);
  });

  it("keeps the merged source mapping and per-fact provenance classifications", () => {
    const merged = baladiyahDraftCurriculum.modules[2];
    assert.equal(merged?.stable_key, "contamination-foodborne-illness-prevention");
    assert.deepEqual(merged?.metadata.source_module_ids, ["food-contamination", "foodborne-illness"]);

    for (const [index, module] of baladiyahDraftCurriculum.modules.entries()) {
      const expected = index < 2 ? "baladiyah_explicit" : "existing_training_supporting";
      assert.equal(module.metadata.default_provenance_classification, expected);
      assert.ok(module.metadata.provenance_facts.length > 0);
      assert.ok(module.metadata.provenance_facts.every((fact) => fact.provenance_classification === expected));
    }
  });

  it("defines only needed, URL-free photo requirements with complete alt text", () => {
    const expectedCounts = [3, 4, 3, 4, 4, 4, 4, 4, 4];
    assert.deepEqual(
      baladiyahDraftCurriculum.modules.map((module) => module.metadata.photo_requirements.length),
      expectedCounts,
    );
    assert.equal(expectedCounts.reduce((total, count) => total + count, 0), 34);

    const assetKeys = new Set<string>();
    for (const module of baladiyahDraftCurriculum.modules) {
      for (const photo of module.metadata.photo_requirements) {
        assert.equal(photo.approval_status, "needed");
        assert.ok(!assetKeys.has(photo.asset_key), `duplicate photo asset key ${photo.asset_key}`);
        assetKeys.add(photo.asset_key);
        assert.doesNotMatch(JSON.stringify(photo), /https?:\/\//iu);
      }
    }
  });

  it("defines three source-backed questions per module and keeps answers outside learner content", () => {
    for (const module of baladiyahDraftCurriculum.modules) {
      const quiz = module.lessons[2];
      assert.equal(quiz?.lesson_type, "quiz");
      const englishQuestions = quiz?.content_i18n.en.questions ?? [];
      assert.equal(englishQuestions.length, 3);
      assert.equal(new Set(englishQuestions.map((question) => question.stable_key)).size, 3);

      const answerKeys = quiz?.metadata.answer_key_by_question ?? {};
      const provenance = quiz?.metadata.question_provenance ?? [];
      assert.equal(Object.keys(answerKeys).length, 3);
      assert.equal(provenance.length, 3);
      for (const question of englishQuestions) {
        assert.equal("correct_option_key" in question, false);
        assert.ok(question.options.length >= 3);
        assert.ok(answerKeys[question.stable_key as keyof typeof answerKeys]);
        assert.ok(question.source_fact_keys.length > 0);
      }
    }
  });

  it("has complete five-locale objects without known Indonesian leakage into other locales", () => {
    visit(baladiyahDraftCurriculum);
    const indonesianLeak = /\b(?:berapa|kapan|harus|jangan|setelah|makanan|dengan|untuk|saat)\b/iu;

    function inspectLocalized(value: unknown): void {
      if (Array.isArray(value)) return value.forEach(inspectLocalized);
      if (!value || typeof value !== "object") return;
      for (const [key, child] of Object.entries(value)) {
        if (localeKeyPattern.test(key) && child && typeof child === "object" && !Array.isArray(child)) {
          for (const locale of ["en", "ar", "hi", "fil"] as const) {
            assert.doesNotMatch(String((child as Record<string, unknown>)[locale]), indonesianLeak);
          }
        }
        inspectLocalized(child);
      }
    }

    inspectLocalized(baladiyahDraftCurriculum);
  });

  it("keeps the generated migration manifest byte-for-byte equivalent to the source manifest", () => {
    const match = migration.match(/\$manifest\$\n([\s\S]*?)\n\$manifest\$::jsonb/u);
    assert.ok(match?.[1], "generated migration must embed the canonical manifest");
    assert.deepEqual(JSON.parse(match[1]), JSON.parse(JSON.stringify(baladiyahDraftCurriculum)));
  });
});

