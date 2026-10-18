import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {describe,it} from "node:test";

const approvals=readFileSync(new URL("../../supabase/migrations/20261018130000_training_publication_approval_foundation.sql",import.meta.url),"utf8");
const lifecycle=readFileSync(new URL("../../supabase/migrations/20261018140000_training_publication_lifecycle.sql",import.meta.url),"utf8");
const readiness=readFileSync(new URL("./training-media.ts",import.meta.url),"utf8");
const sql=`${approvals}\n${lifecycle}`;

describe("Training publication foundation SQL boundary",()=>{
  it("reuses Internal Admin authorization and exposes no browser mutation grants",()=>{
    for(const rpc of [
      "submit_internal_admin_training_version_for_review",
      "review_internal_admin_training_version",
      "revoke_internal_admin_training_version_approval",
      "begin_internal_admin_training_storage_verification",
      "retire_internal_admin_training_course_version",
      "activate_internal_admin_restaurant_training_program",
      "retire_internal_admin_training_program",
    ]){
      assert.match(sql,new RegExp(`revoke all on function public\\.${rpc}\\([^;]+from public,anon,authenticated,service_role`));
      assert.match(sql,new RegExp(`grant execute on function public\\.${rpc}\\([^;]+to service_role`));
    }
    for(const rpc of ["complete_internal_admin_training_storage_verification","publish_internal_admin_training_course_version"]){
      assert.match(sql,new RegExp(`revoke all on function public\\.${rpc}\\([^;]+from public,anon,authenticated,service_role`));
      assert.doesNotMatch(sql,new RegExp(`grant execute on function public\\.${rpc}\\([^;]+to service_role`));
    }
    assert.match(sql,/private\.is_internal_admin\(actor_user_id\)/);
    assert.doesNotMatch(sql,/create (?:table|type).*content_reviewer|translation_reviewer|regulatory_reviewer|publisher_role/i);
  });

  it("serializes child mutations, enrollment, publication, and retirement on the version",()=>{
    assert.match(approvals,/private\.lock_training_course_version/);
    assert.match(approvals,/enforce_training_draft_content[\s\S]*lock_training_course_version\(old\.organization_id,old\.course_version_id,'draft'\)/);
    assert.match(approvals,/enforce_training_media_draft[\s\S]*lock_training_course_version\(old\.organization_id,old\.course_version_id,'draft'\)/);
    assert.match(lifecycle,/enforce_training_enrollment_published_version[\s\S]*lock_training_course_version[\s\S]*'published'/);
    assert.match(lifecycle,/publish_internal_admin_training_course_version[\s\S]*lock_training_course_version[\s\S]*'draft'/);
    assert.match(lifecycle,/retire_internal_admin_training_course_version[\s\S]*lock_training_course_version[\s\S]*'published'/);
  });

  it("keeps immutable contributor history and snapshots every contributor at submission",()=>{
    assert.match(approvals,/create table public\.training_content_contributor_events/);
    assert.match(approvals,/create table public\.training_media_contributor_events/);
    assert.match(approvals,/create table public\.training_publication_submission_contributors/);
    assert.match(approvals,/capture_training_content_contributor/);
    assert.match(approvals,/capture_training_media_contributor/);
    assert.match(approvals,/contributor\.contributor_user_id=actor_user_id/);
    assert.match(approvals,/actor_user_id=any\(contributor_ids\)/);
  });

  it("preserves legacy decisions and resets only draft media",()=>{
    assert.match(approvals,/asset\.approval_status,asset\.reviewed_by[\s\S]*asset\.reviewed_at,asset\.rejection_reason/);
    assert.match(approvals,/original_reviewed_at/);
    assert.match(approvals,/version\.status='draft' and asset\.approval_status in \('approved','rejected'\)/);
    assert.doesNotMatch(approvals,/where approval_status in \('approved','rejected'\);/);
  });

  it("binds decisions to exact scope, revision, and a server-computed fingerprint",()=>{
    assert.match(approvals,/private\.training_publication_content_fingerprint/);
    assert.match(approvals,/organization_id.*course_id.*course_version_id.*version_revision[\s\S]*content_fingerprint/);
    assert.match(approvals,/submission\.content_fingerprint is distinct from current_fingerprint/);
    assert.match(approvals,/Training self-approval is forbidden/);
    assert.match(approvals,/training_publication_submission_contributors[\s\S]*contributor_user_id=actor_user_id/);
    assert.match(approvals,/private\.training_actor_modified_version/);
    assert.match(approvals,/Training review decision was already recorded/);
  });

  it("keeps approval, rejection, revocation, invalidation, and lifecycle history immutable",()=>{
    for(const table of [
      "training_publication_review_submissions","training_publication_review_events",
      "training_media_review_events","training_storage_verification_items",
      "training_publication_lifecycle_events",
    ])assert.match(sql,new RegExp(`${table}_(?:immutability|[a-z_]+_immutability)`));
    assert.match(approvals,/decision in \('approved','rejected','revoked'\)/);
    assert.match(approvals,/decision in \('approved','rejected','invalidated'\)/);
    assert.match(lifecycle,/event_type in \('published','retired','program_activated','program_retired'\)/);
    assert.match(sql,/Training audit records are immutable/);
  });

  it("requires fresh one-use backend evidence instead of pretending PostgreSQL read Storage bytes",()=>{
    assert.match(lifecycle,/challenge_nonce uuid not null default gen_random_uuid\(\)/);
    assert.match(lifecycle,/expires_at timestamptz not null default \(statement_timestamp\(\) \+ interval '10 minutes'\)/);
    assert.match(lifecycle,/run\.verified_at < statement_timestamp\(\)-interval '5 minutes'/);
    assert.match(lifecycle,/status='consumed',consumed_at=statement_timestamp\(\)/);
    assert.match(lifecycle,/observed_sha256<>asset\.sha256/);
    assert.doesNotMatch(lifecycle,/storage\.objects|lo_get|pg_read_binary_file/);
    assert.doesNotMatch(lifecycle,/grant execute on function public\.complete_internal_admin_training_storage_verification[\s\S]*to service_role/);
    assert.doesNotMatch(lifecycle,/grant execute on function public\.publish_internal_admin_training_course_version[\s\S]*to service_role/);
  });

  it("keeps the approved fingerprint reproducible and protects it after publication",()=>{
    const fingerprint=approvals.slice(approvals.indexOf("create or replace function private.training_publication_content_fingerprint"),approvals.indexOf("create or replace function private.training_actor_modified_version"));
    assert.doesNotMatch(fingerprint,/canonical_content_hash|version\.content_hash/);
    assert.match(lifecycle,/new\.publication_fingerprint is not distinct from old\.publication_fingerprint/);
  });

  it("publishes under a lock only after canonical curriculum, reviews, media, and Storage checks",()=>{
    const publish=lifecycle.slice(lifecycle.indexOf("create or replace function public.publish_internal_admin_training_course_version"));
    assert.match(publish,/pg_advisory_xact_lock/);
    assert.match(publish,/version\.version_number<>1 or version\.revision<>2/);
    assert.match(publish,/get_internal_admin_training_draft_preview/);
    assert.match(publish,/validate_internal_admin_training_media_for_publish/);
    assert.match(publish,/training_submission_is_publishable/);
    assert.match(publish,/conflict\.status='published'/);
    assert.match(publish,/publication_fingerprint=current_fingerprint/);
  });

  it("activates exactly Baladiyah then dependent unpublished Restaurant SOP",()=>{
    const activate=lifecycle.slice(lifecycle.indexOf("create or replace function public.activate_internal_admin_restaurant_training_program"));
    assert.match(activate,/count\(\*\).*<>2/);
    assert.match(activate,/entry\.position=1.*course\.course_key='baladiyah-food-safety-hygiene'/s);
    assert.match(activate,/entry\.position=2.*course\.course_key='restaurant-sop'/s);
    assert.match(activate,/sop_entry\.prerequisite_program_course_id<>baladiyah_entry\.id/);
    assert.match(activate,/version\.status='published'/);
    assert.match(activate,/Restaurant SOP must remain unpublished until its curriculum is ready/);
    assert.match(lifecycle,/create or replace function public\.retire_internal_admin_training_program/);
  });

  it("preserves historical tables and safely blocks retirement with active dependencies",()=>{
    const retire=lifecycle.slice(lifecycle.indexOf("create or replace function public.retire_internal_admin_training_course_version"));
    assert.match(retire,/training_program_courses[\s\S]*program\.status='active'/);
    assert.match(retire,/training_enrollments[\s\S]*training_course_completions/);
    assert.doesNotMatch(sql,/delete from public\.training_(?:enrollments|lesson_progress|quiz_attempts|course_completions)/);
    assert.doesNotMatch(sql,/drop table|truncate table/i);
  });

  it("keeps every new definer function on an empty search path and updates readiness compatibility",()=>{
    const definerCount=(sql.match(/security definer/g)??[]).length;
    const emptyPathCount=(sql.match(/set search_path = ''/g)??[]).length;
    assert.equal(emptyPathCount,definerCount);
    assert.match(readiness,/review_workflow_available:z\.boolean\(\)/);
    assert.match(readiness,/row\.translation_review_status\[locale\]!=="approved"/);
    assert.match(readiness,/workflow_available:row\.review_workflow_available/);
  });
});
