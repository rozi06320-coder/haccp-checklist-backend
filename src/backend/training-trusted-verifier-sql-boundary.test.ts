import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {describe,it} from "node:test";

const sql=readFileSync(new URL("../../supabase/migrations/20261018150000_training_trusted_verifier_api.sql",import.meta.url),"utf8");
const worker=readFileSync(new URL("training-storage-verifier-server.ts",import.meta.url),"utf8");
const verifier=readFileSync(new URL("training-storage-verifier.ts",import.meta.url),"utf8");
const supabaseConfig=readFileSync(new URL("../../supabase/config.toml",import.meta.url),"utf8");

describe("Training trusted verifier SQL boundary",()=>{
  it("uses a digest-backed capability broker and provisions no database login or role membership",()=>{
    assert.match(sql,/create table private\.training_verifier_capabilities/i);
    assert.match(sql,/secret_sha256=extensions\.digest/i);
    assert.doesNotMatch(sql,/create\s+role|alter\s+role|\bpg_net\b|\bnet\.http|grant\s+training_/i);
    assert.doesNotMatch(worker,/DATABASE_URL|SUPABASE_SECRET_KEY|\bPool\b|\bpg\b/);
    assert.match(supabaseConfig,/schemas\s*=\s*\["public",\s*"graphql_public"\]/);
    assert.doesNotMatch(supabaseConfig,/schemas\s*=\s*\[[^\]]*"(?:net|extensions)"/);
  });
  it("does not let service_role execute any verifier claim, failure, or completion broker",()=>{
    for(const name of ["claim_training_storage_verifier_job","fail_training_storage_verifier_job","block_training_storage_verifier_job_after_source_verification"]){
      assert.match(sql,new RegExp(`revoke all on function public\\.${name}[\\s\\S]*?service_role`));
      assert.doesNotMatch(sql,new RegExp(`grant execute on function public\\.${name}[\\s\\S]*?to service_role`,`i`));
      assert.match(sql,new RegExp(`grant execute on function public\\.${name}[\\s\\S]*?to anon`,`i`));
    }
  });
  it("keeps Phase 3A completion and publication ungranted and uncalled",()=>{
    assert.doesNotMatch(sql,/grant execute on function public\.(complete_internal_admin_training_storage_verification|publish_internal_admin_training_course_version)/i);
    assert.doesNotMatch(sql,/perform \* from public\.complete_internal_admin_training_storage_verification|select \* from public\.publish_internal_admin_training_course_version/i);
    assert.match(sql,/state='publication_blocked'/i);assert.match(sql,/immutable_store_unconfigured/i);
  });
  it("makes requests, observations, and events immutable while queue leases are bounded",()=>{
    for(const trigger of ["training_publication_requests_immutability","training_verifier_events_immutability","training_verifier_source_observations_immutability"])assert.match(sql,new RegExp(trigger));
    assert.match(sql,/max_attempts integer not null default 3/i);assert.match(sql,/lease_expires_at/i);
    assert.match(sql,/for update/i);assert.match(sql,/retry_limit_exhausted/i);
    assert.match(sql,/training_verifier_events_replay_key unique/i);
  });
  it("binds canonical jobs to protocol, audience, key, nonce, timestamps, exact scope, revision, and fingerprint",()=>{
    for(const field of ["protocol_version","audience","key_id","actor_user_id","organization_id","course_id","course_version_id","submission_id","verification_run_id","challenge_nonce","issued_at_epoch_seconds","expires_at_epoch_seconds","expected_revision","expected_content_fingerprint","action_request_id"])assert.match(sql,new RegExp(`'${field}'`));
    assert.match(sql,/authorization_signature~'\^\[A-Za-z0-9\+\/\]\{86\}==\$'/);
  });
  it("gives the verifier JWT source-object SELECT only and never a broad Storage credential",()=>{
    assert.match(sql,/create policy training_verifier_source_object_read[\s\S]*for select to authenticated/i);
    assert.doesNotMatch(sql,/training_verifier_source_object_(insert|update|delete)|for (insert|update|delete) to authenticated/i);
    assert.match(worker,/TRAINING_VERIFIER_STORAGE_ACCESS_TOKEN/);assert.doesNotMatch(worker,/SERVICE_ROLE|SECRET_KEY/);
  });
  it("uses version, run, then job lock order in claim, failure, and source completion",()=>{
    for(const name of ["claim_training_storage_verifier_job","fail_training_storage_verifier_job","block_training_storage_verifier_job_after_source_verification"]){
      const start=sql.indexOf(`create or replace function public.${name}`),end=sql.indexOf("$$;",start),body=sql.slice(start,end);
      const lock=body.indexOf("lock_training_course_version"),runLock=body.indexOf("from public.training_storage_verification_runs",lock),jobLock=body.indexOf("from public.training_verifier_jobs",runLock);
      assert.ok(lock>=0&&runLock>lock&&jobLock>runLock);
    }
  });
  it("streams from a fixed Storage origin with timeout, byte cap, and concurrency two",()=>{
    assert.match(verifier,/response\.body\.getReader\(\)/);assert.match(verifier,/AbortController/);
    assert.match(verifier,/MAX_TRAINING_MEDIA_SOURCE_BYTES/);assert.match(verifier,/target\.origin!==origin\.origin/);
    assert.match(verifier,/Math\.min\(2,rows\.length\)/);assert.match(verifier,/redirect:"error"/);
  });
  it("all migration functions are SECURITY DEFINER with an empty search path and no dynamic SQL",()=>{
    const functions=sql.match(/create or replace function[\s\S]*?\$\$;/gi)??[];assert.ok(functions.length>=8);
    for(const fn of functions){assert.match(fn,/security definer/i);assert.match(fn,/set search_path=''|set search_path = ''/i);assert.doesNotMatch(fn,/execute\s+format|execute\s+[^;]+using/i);}
  });
});
