import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {describe,it} from "node:test";

const migration=new URL("../../supabase/migrations/20261017010000_training_program_prerequisites.sql",import.meta.url);

describe("Training program SQL boundary",()=>{
  it("creates organization-scoped ordered programs and nullable historical enrollment scope",async()=>{
    const sql=await readFile(migration,"utf8");
    assert.match(sql,/create table public\.training_programs/);
    assert.match(sql,/create table public\.training_program_courses/);
    assert.match(sql,/foreign key\(prerequisite_program_course_id, program_id, organization_id\)/);
    assert.match(sql,/add column program_course_id uuid/);
    assert.doesNotMatch(sql,/update public\.training_enrollments[\s\S]*program_course_id/i);
  });

  it("fails closed before enforcing one published version per course",async()=>{
    const sql=await readFile(migration,"utf8");
    assert.match(sql,/having count\(\*\) > 1[\s\S]*raise exception 'A Training course has multiple published versions'/);
    assert.match(sql,/create unique index training_course_versions_one_published_idx[\s\S]*where status = 'published'/);
  });

  it("centralizes prerequisite checks for enrollment and every scoped enrollment operation",async()=>{
    const sql=await readFile(migration,"utf8");
    assert.match(sql,/create or replace function private\.assert_training_program_course_eligible/);
    assert.match(sql,/create or replace function private\.assert_training_progress_enrollment[\s\S]*selected\.program_course_id is not null[\s\S]*assert_training_program_course_eligible/);
    assert.match(sql,/initialize_training_program_enrollment/);
    assert.match(sql,/Program prerequisite enrollment requires program scope/);
  });

  it("requires permanent passing evidence for the same employee and organization",async()=>{
    const sql=await readFile(migration,"utf8");
    assert.match(sql,/completion\.employee_id = target_employee_id/);
    assert.match(sql,/completion\.course_id = prerequisite\.course_id/);
    assert.match(sql,/attempt\.status = 'submitted'[\s\S]*attempt\.passed/);
    assert.match(sql,/version\.status in \('published','retired'\)/);
  });

  it("exposes only service-role hardened public RPCs",async()=>{
    const sql=await readFile(migration,"utf8");
    for(const name of ["initialize_training_program_enrollment","get_training_program_status","provision_internal_admin_restaurant_training_program"]){
      assert.match(sql,new RegExp(`create or replace function public\\.${name}[\\s\\S]*security definer[\\s\\S]*set search_path = ''`));
      assert.match(sql,new RegExp(`revoke all on function public\\.${name}`));
      assert.match(sql,new RegExp(`grant execute on function public\\.${name}`));
    }
    assert.match(sql,/revoke all on table public\.training_programs from public, anon, authenticated, service_role/);
    assert.match(sql,/revoke all on table public\.training_program_courses from public, anon, authenticated, service_role/);
  });

  it("provisions only an explicit authorized organization and creates no SOP version or learner state",async()=>{
    const sql=await readFile(migration,"utf8");
    assert.match(sql,/private\.is_internal_admin\(actor_user_id\)/);
    assert.match(sql,/target_organization_id/);
    assert.doesNotMatch(sql,/from public\.organizations[\s\S]{0,200}limit 1/i);
    assert.doesNotMatch(sql,/insert into public\.training_course_versions/i);
    assert.doesNotMatch(sql,/insert into public\.training_lesson_progress/i);
    assert.doesNotMatch(sql,/insert into public\.training_quiz_attempts/i);
  });
});
