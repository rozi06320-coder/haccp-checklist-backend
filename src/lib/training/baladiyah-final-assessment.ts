import {
  baladiyahDraftCurriculum,
  trainingLocales,
  type LocalizedText,
  type TrainingLocale,
} from "./baladiyah-draft-curriculum.js";

type JsonObject = Record<string, unknown>;

const text = (en: string, ar: string, id: string, hi: string, fil: string): LocalizedText => ({
  en,
  ar,
  id,
  hi,
  fil,
});

const clone = <T>(value: T): T => structuredClone(value);

function normalizedInstructionalContent(
  module: (typeof baladiyahDraftCurriculum.modules)[number],
  lessonKey: "overview" | "practical-photo-guide",
) {
  const lesson = module.lessons.find((candidate) => candidate.stable_key === lessonKey);
  if (!lesson) throw new Error(`Missing instructional lesson ${module.stable_key}:${lessonKey}`);

  const requirements = module.metadata.photo_requirements.filter(
    (requirement) => requirement.lesson_key === lessonKey,
  );

  if (requirements.length === 0) return clone(lesson);

  return {
    ...clone(lesson),
    max_attempts: null,
    retry_delay_seconds: 0,
    content_i18n: Object.fromEntries(
      trainingLocales.map((locale) => {
        const localeContent = clone(lesson.content_i18n[locale]) as JsonObject;
        const items = Array.isArray(localeContent.items)
          ? localeContent.items.map((item) => {
              if (!item || typeof item !== "object" || Array.isArray(item)) return item;
              const { image: _legacyImage, ...normalizedItem } = item as JsonObject;
              return normalizedItem;
            })
          : localeContent.items;

        return [
          locale,
          {
            ...localeContent,
            ...(items === undefined ? {} : { items }),
            image_slots: requirements.map((requirement, index) => ({
              asset_key: requirement.asset_key,
              placement: requirement.placement,
              slot_position: index + 1,
              label: requirement.alt_i18n[locale],
            })),
          },
        ];
      }),
    ) as Record<TrainingLocale, JsonObject>,
  };
}

const sourceQuizzes = baladiyahDraftCurriculum.modules.map((module) => {
  const lesson = module.lessons.find((candidate) => candidate.lesson_type === "quiz");
  if (!lesson) throw new Error(`Missing source quiz for ${module.stable_key}`);
  return { module, lesson };
});

const questionGroups = sourceQuizzes.map(({ module, lesson }) => ({
  source_module_key: module.stable_key,
  source_module_position: module.position,
  question_keys: lesson.content_i18n.en.questions.map((question) => question.stable_key),
}));

const answerKeyByQuestion = Object.assign(
  {},
  ...sourceQuizzes.map(({ lesson }) => lesson.metadata.answer_key_by_question),
) as Record<string, string>;

const questionProvenance = sourceQuizzes.flatMap(({ lesson }) =>
  clone(lesson.metadata.question_provenance),
);

const finalQuizContent = Object.fromEntries(
  trainingLocales.map((locale) => [
    locale,
    {
      content_schema_version: 1,
      questions: sourceQuizzes.flatMap(({ lesson }) => clone(lesson.content_i18n[locale].questions)),
    },
  ]),
) as Record<TrainingLocale, JsonObject>;

export const baladiyahFinalAssessmentModule = {
  stable_key: "final-assessment",
  position: 10,
  category_key: null,
  title_i18n: text(
    "Final Assessment",
    "التقييم النهائي",
    "Penilaian Akhir",
    "अंतिम मूल्यांकन",
    "Panghuling Pagtatasa",
  ),
  description_i18n: text(
    "Final course assessment covering the nine instructional modules.",
    "التقييم النهائي للدورة ويغطي الوحدات التعليمية التسع.",
    "Penilaian akhir kursus yang mencakup sembilan modul pembelajaran.",
    "नौ शिक्षण मॉड्यूल को शामिल करने वाला अंतिम पाठ्यक्रम मूल्यांकन।",
    "Panghuling pagtatasa ng kurso na sumasaklaw sa siyam na instructional module.",
  ),
  metadata: {
    module_role: "final_assessment",
  },
  lessons: [
    {
      stable_key: "final-quiz",
      position: 1,
      lesson_type: "quiz",
      required: true,
      title_i18n: text(
        "Final Quiz",
        "الاختبار النهائي",
        "Kuis Akhir",
        "अंतिम क्विज़",
        "Panghuling Pagsusulit",
      ),
      objective_i18n: text(
        "Complete the final assessment for all nine instructional modules.",
        "أكمل التقييم النهائي لجميع الوحدات التعليمية التسع.",
        "Selesaikan penilaian akhir untuk seluruh sembilan modul pembelajaran.",
        "सभी नौ शिक्षण मॉड्यूल के लिए अंतिम मूल्यांकन पूरा करें।",
        "Kumpletuhin ang panghuling pagtatasa para sa lahat ng siyam na instructional module.",
      ),
      content_i18n: finalQuizContent,
      estimated_duration_seconds: null,
      minimum_engagement_seconds: 0,
      pass_threshold_bps: 8000,
      max_attempts: null,
      retry_delay_seconds: 0,
      metadata: {
        content_schema_version: 1,
        curriculum_status: "draft",
        translation_review_status: "draft",
        assessment_scope: "course",
        answer_key_by_question: answerKeyByQuestion,
        question_provenance: questionProvenance,
        question_groups: questionGroups,
      },
    },
  ],
} as const;

const instructionalModules = baladiyahDraftCurriculum.modules.map((module) => ({
  ...clone(module),
  lessons: [
    { max_attempts: null, retry_delay_seconds: 0, ...normalizedInstructionalContent(module, "overview") },
    {
      max_attempts: null,
      retry_delay_seconds: 0,
      ...normalizedInstructionalContent(module, "practical-photo-guide"),
    },
  ],
}));

export const baladiyahFinalAssessmentCurriculum = {
  ...clone(baladiyahDraftCurriculum),
  modules: [...instructionalModules, baladiyahFinalAssessmentModule],
} as const;

export const baladiyahFinalAssessmentSourceQuizzes = sourceQuizzes.map(({ module, lesson }) => ({
  source_module_key: module.stable_key,
  source_module_position: module.position,
  lesson: clone(lesson),
}));

export const baladiyahFinalAssessmentImageSlotTuples = instructionalModules
  .flatMap((module) =>
    module.metadata.photo_requirements.map((requirement) => {
    const lesson = module.lessons.find((candidate) => candidate.stable_key === requirement.lesson_key);
    if (!lesson) throw new Error(`Missing image-slot lesson ${module.stable_key}:${requirement.lesson_key}`);
    const lessonRequirements = module.metadata.photo_requirements.filter(
      (candidate) => candidate.lesson_key === requirement.lesson_key,
    );
      return {
        module_position: module.position,
        lesson_position: lesson.position,
        module_key: module.stable_key,
      lesson_key: lesson.stable_key,
      asset_key: requirement.asset_key,
      placement: requirement.placement,
      slot_position: lessonRequirements.findIndex(
        (candidate) => candidate.asset_key === requirement.asset_key,
      ) + 1,
      };
    }),
  )
  .sort(
    (left, right) =>
      left.module_position - right.module_position ||
      left.lesson_position - right.lesson_position ||
      left.slot_position - right.slot_position,
  )
  .map(({ module_position: _modulePosition, lesson_position: _lessonPosition, ...tuple }) => tuple);

export const baladiyahFinalAssessmentScoring = {
  question_count: 27,
  pass_threshold_bps: 8000,
  minimum_correct_count: 22,
  formula: "correct_count * 10000 >= question_count * pass_threshold_bps",
  future_unlock_rule: "all_18_required_non_quiz_lessons_completed",
  future_completion_rule: "all_18_instructional_lessons_completed_and_one_submitted_passing_attempt",
} as const;
