import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {describe,it} from "node:test";

const sql=readFileSync(new URL("../../supabase/migrations/20261020120000_training_single_project_published_media.sql",import.meta.url),"utf8");
const audienceBoundary=readFileSync(new URL("../../supabase/migrations/20261020130000_training_integrity_audience_boundary.sql",import.meta.url),"utf8");
const verifier=readFileSync(new URL("training-storage-verifier.ts",import.meta.url),"utf8");
const progress=readFileSync(new URL("training-progress.ts",import.meta.url),"utf8");
const preview=readFileSync(new URL("training-employee-preview.ts",import.meta.url),"utf8");

describe("single-project published Training media boundary",()=>{
  it("creates one private WebP bucket with verifier SELECT/INSERT but no UPDATE/DELETE policy",()=>{
    assert.match(sql,/values\('training-published-media','training-published-media',false,5242880,array\['image\/webp'\]\)/);
    assert.match(sql,/create policy training_verifier_published_object_read[\s\S]*for select to authenticated/i);
    assert.match(sql,/create policy training_verifier_published_object_insert[\s\S]*for insert to authenticated/i);
    assert.doesNotMatch(sql,/create policy training_verifier_published_object_(?:update|delete)|for (?:update|delete) to authenticated/i);
    assert.match(sql,/service-role credential can bypass Storage/i);
  });
  it("binds immutable roots, forty scoped items, and append-only integrity evidence",()=>{
    for(const table of ["training_publication_media_manifests","training_publication_media_manifest_items","training_published_media_integrity_runs","training_published_media_integrity_items"]){
      assert.match(sql,new RegExp(`create table public\\.${table}`));assert.match(sql,new RegExp(`alter table public\\.${table} enable row level security`));
      assert.match(sql,new RegExp(`${table}.*immutability`));
    }
    assert.match(sql,/object_count=40/);assert.match(sql,/jsonb_array_length\(published_manifest_items\)<>40/);
    assert.match(sql,/foreign key\(manifest_id,organization_id,course_id,course_version_id\)/);
    assert.match(sql,/storage_object_path='sha256\/'\|\|substring\(sha256 from 1 for 2\)/);
    assert.match(sql,/left join storage\.objects object on object\.bucket_id='training-published-media'/);
    assert.match(sql,/recorded_sequence bigint generated always as identity/);
  });
  it("keeps Phase 3A completion/publication ungranted behind capability and lease finalization",()=>{
    for(const name of ["complete_internal_admin_training_storage_verification","publish_internal_admin_training_course_version"]){
      assert.match(sql,new RegExp(`revoke all on function public\\.${name}[\\s\\S]*service_role`));
      assert.doesNotMatch(sql,new RegExp(`grant execute on function public\\.${name}`));
    }
    assert.match(sql,/assert_training_verifier_capability/);assert.match(sql,/job\.state<>'leased'/);
    assert.match(sql,/complete_internal_admin_training_storage_verification/);assert.match(sql,/publish_internal_admin_training_course_version/);
    assert.match(sql,/exception when unique_violation/);
  });
  it("guards manifest binding and fails official reads closed on stale or failed integrity",()=>{
    assert.match(sql,/current_setting\('app\.training_manifest_binding',true\)/);
    assert.match(sql,/latest\.status='passed'/);assert.match(sql,/integrity_freshness_seconds/);
    assert.match(sql,/checked_object_count=40/);assert.match(sql,/training_course_versions_02_manifest_publication_gate/);
  });
  it("promotes exact bytes with no upsert and re-downloads before finalization",()=>{
    assert.match(verifier,/"x-upsert":"false"/);assert.match(verifier,/uploadImmutable/);
    assert.match(verifier,/download\(TRAINING_PUBLISHED_MEDIA_BUCKET,objectPath\)/);
    assert.match(verifier,/trainingPublishedManifestFingerprint/);assert.match(verifier,/database\.finalize/);
    assert.doesNotMatch(verifier,/SUPABASE_SECRET_KEY|service_role/i);
  });
  it("switches only official media to published manifests and leaves draft preview isolated",()=>{
    assert.match(progress,/authorize_training_published_media_read/);assert.match(progress,/training-published-media/);
    assert.doesNotMatch(progress,/authorize_legacy_training_media_read/);
    assert.match(preview,/authorize_training_employee_baladiyah_draft_preview_media/);assert.match(preview,/training-media/);
    assert.doesNotMatch(preview,/training-published-media/);
  });
  it("uses only SECURITY DEFINER empty-search-path functions and no dynamic SQL",()=>{
    const functions=sql.match(/create or replace function[\s\S]*?\$\$;/gi)??[];assert.ok(functions.length>=9);
    for(const fn of functions){assert.match(fn,/security definer/i);assert.match(fn,/set search_path=''|set search_path = ''/i);assert.doesNotMatch(fn,/execute\s+format|execute\s+[^;]+using/i);}
  });
  it("binds integrity leases and completions to the immutable publication request audience",()=>{
    assert.match(audienceBoundary,/join public\.training_publication_requests publication_request[\s\S]*publication_request\.id=manifest\.publication_request_id/i);
    assert.match(audienceBoundary,/publication_request\.organization_id=manifest\.organization_id/);
    assert.match(audienceBoundary,/publication_request\.course_id=manifest\.course_id/);
    assert.match(audienceBoundary,/publication_request\.course_version_id=manifest\.course_version_id/);
    assert.equal((audienceBoundary.match(/publication_request\.audience=expected_audience/g)??[]).length,2);
    assert.match(audienceBoundary,/for update of job skip locked/);
    assert.match(audienceBoundary,/for update of target/);
    assert.match(audienceBoundary,/Training verifier access denied/);
  });
  it("preserves integrity RPC signatures, least-privilege grants, and empty search paths",()=>{
    assert.match(audienceBoundary,/create or replace function public\.claim_training_published_media_integrity_audit\([\s\S]*target_capability_id uuid,capability_secret text,expected_audience text,[\s\S]*worker_instance_id uuid,claim_request_id uuid[\s\S]*security definer set search_path=''/i);
    assert.match(audienceBoundary,/create or replace function public\.complete_training_published_media_integrity_audit\([\s\S]*target_manifest_id uuid,[\s\S]*completion_request_id uuid[\s\S]*security definer set search_path=''/i);
    assert.match(audienceBoundary,/revoke all on function public\.claim_training_published_media_integrity_audit\([\s\S]*from public,anon,authenticated,service_role/);
    assert.match(audienceBoundary,/grant execute on function public\.claim_training_published_media_integrity_audit\([\s\S]*to anon/);
    assert.doesNotMatch(audienceBoundary,/grant execute[\s\S]*to (?:authenticated|service_role)/i);
    assert.doesNotMatch(audienceBoundary,/execute\s+format|execute\s+[^;]+using/i);
  });
});
