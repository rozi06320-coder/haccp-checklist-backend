import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { baladiyahDraftCurriculum, trainingLocales } from "../lib/training/baladiyah-draft-curriculum.js";
import {
  baladiyahFinalAssessmentCurriculum,
  baladiyahFinalAssessmentImageSlotTuples,
  baladiyahFinalAssessmentScoring,
} from "../lib/training/baladiyah-final-assessment.js";

const migration = readFileSync(
  new URL("../../supabase/migrations/20261015220000_baladiyah_final_assessment.sql", import.meta.url),
  "utf8",
);

const sourceQuizzes = baladiyahDraftCurriculum.modules.map((module) => ({
  module,
  quiz: module.lessons.find((lesson) => lesson.lesson_type === "quiz")!,
}));
const finalModule = baladiyahFinalAssessmentCurriculum.modules[9];
const finalQuiz = finalModule.lessons[0];

describe("Baladiyah final assessment manifest", () => {
  it("retains nine instructional modules and moves all quizzes into one final module", () => {
    assert.equal(baladiyahFinalAssessmentCurriculum.modules.length, 10);
    assert.deepEqual(
      baladiyahFinalAssessmentCurriculum.modules.slice(0, 9).map((module) => module.stable_key),
      baladiyahDraftCurriculum.modules.map((module) => module.stable_key),
    );
    for (const module of baladiyahFinalAssessmentCurriculum.modules.slice(0, 9)) {
      assert.deepEqual(module.lessons.map((lesson) => lesson.stable_key), ["overview", "practical-photo-guide"]);
    }

    const lessons = baladiyahFinalAssessmentCurriculum.modules.flatMap((module) => module.lessons);
    assert.equal(lessons.length, 19);
    assert.equal(lessons.filter((lesson) => lesson.lesson_type === "reading").length, 9);
    assert.equal(lessons.filter((lesson) => lesson.lesson_type === "key_points").length, 9);
    assert.equal(lessons.filter((lesson) => lesson.lesson_type === "quiz").length, 1);
    assert.equal(finalModule.stable_key, "final-assessment");
    assert.equal(finalModule.position, 10);
    assert.deepEqual(finalModule.metadata, { module_role: "final_assessment" });
  });

  it("preserves every question payload and answer/provenance record without rewriting", () => {
    assert.equal(finalQuiz.stable_key, "final-quiz");
    assert.equal(finalQuiz.lesson_type, "quiz");
    for (const locale of trainingLocales) {
      const sourceQuestions = sourceQuizzes.flatMap(({ quiz }) => quiz.content_i18n[locale].questions);
      assert.deepEqual(finalQuiz.content_i18n[locale].questions, sourceQuestions);
      assert.equal(finalQuiz.content_i18n[locale].questions.length, 27);
    }

    const sourceAnswerKeys = Object.assign({}, ...sourceQuizzes.map(({ quiz }) => quiz.metadata.answer_key_by_question));
    const sourceProvenance = sourceQuizzes.flatMap(({ quiz }) => quiz.metadata.question_provenance);
    assert.deepEqual(finalQuiz.metadata.answer_key_by_question, sourceAnswerKeys);
    assert.deepEqual(finalQuiz.metadata.question_provenance, sourceProvenance);
    assert.equal(new Set(Object.keys(finalQuiz.metadata.answer_key_by_question)).size, 27);
    assert.doesNotMatch(JSON.stringify(finalQuiz.content_i18n), /correct_option_key/u);
  });

  it("groups three questions per source module in deterministic order", () => {
    assert.equal(finalQuiz.metadata.question_groups.length, 9);
    assert.deepEqual(
      finalQuiz.metadata.question_groups,
      sourceQuizzes.map(({ module, quiz }) => ({
        source_module_key: module.stable_key,
        source_module_position: module.position,
        question_keys: quiz.content_i18n.en.questions.map((question) => question.stable_key),
      })),
    );
    assert.ok(finalQuiz.metadata.question_groups.every((group) => group.question_keys.length === 3));
  });

  it("stores the course-scoped 80 percent rule and documents integer scoring", () => {
    assert.equal(finalQuiz.required, true);
    assert.equal(finalQuiz.pass_threshold_bps, 8000);
    assert.equal(finalQuiz.max_attempts, null);
    assert.equal(finalQuiz.retry_delay_seconds, 0);
    assert.equal(finalQuiz.metadata.assessment_scope, "course");
    assert.equal(21 * 10_000 >= 27 * 8_000, false);
    assert.equal(22 * 10_000 >= 27 * 8_000, true);
    assert.equal(baladiyahFinalAssessmentScoring.minimum_correct_count, 22);
  });

  it("keeps the exact forty-slot instructional image contract", () => {
    assert.equal(baladiyahFinalAssessmentImageSlotTuples.length, 40);
    assert.equal(new Set(baladiyahFinalAssessmentImageSlotTuples.map((slot) => JSON.stringify(slot))).size, 40);
    assert.ok(baladiyahFinalAssessmentImageSlotTuples.every((slot) => slot.module_key !== "final-assessment"));
    assert.equal(
      baladiyahFinalAssessmentCurriculum.modules.slice(0, 9)
        .reduce((total, module) => total + module.metadata.photo_requirements.length, 0),
      40,
    );
  });

  it("embeds the target manifest and its deterministic hash", () => {
    const manifestMatch = migration.match(/expected_target_manifest constant jsonb := \$manifest\$\n([\s\S]*?)\n\$manifest\$::jsonb;/u);
    assert.ok(manifestMatch?.[1]);
    assert.deepEqual(JSON.parse(manifestMatch[1]), JSON.parse(JSON.stringify(baladiyahFinalAssessmentCurriculum)));
    const expectedHash = createHash("sha256")
      .update(JSON.stringify(baladiyahFinalAssessmentCurriculum, null, 2))
      .digest("hex");
    assert.equal(expectedHash, "9bfb8467b8a43dc61db87833d0532403d14ecc6d3f63cb57e37582ea32d634d3");
    assert.match(migration, new RegExp(`expected_target_hash constant text := '${expectedHash}'`, "u"));
  });
});
