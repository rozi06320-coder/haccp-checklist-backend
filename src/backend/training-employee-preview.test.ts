import assert from "node:assert/strict";
import {afterEach,describe,it} from "node:test";
import {
  createTrainingEmployeePreviewService,
  getTrainingEmployeePreviewDiagnostic,
  TrainingEmployeePreviewAccessError,
  TrainingEmployeePreviewConflictError,
  TrainingEmployeePreviewUnavailableError,
} from "./training-employee-preview";

const originalFetch=globalThis.fetch;
afterEach(()=>{globalThis.fetch=originalFetch;});

const uuid=(value:number)=>`00000000-0000-4000-8000-${String(value).padStart(12,"0")}`;
const localized={en:"Text",ar:"نص",id:"Teks",hi:"पाठ",fil:"Teksto"};
const identity={organizationId:uuid(1),branchId:uuid(2),employeeId:uuid(3)};
const moduleKeys=["personal-hygiene-health","cleaning-sanitation","contamination-foodborne-illness-prevention","safe-food-handling","food-receiving","storage-temperature-control","cooking-holding-reheating","waste-management","pest-prevention-escalation"];

function canonicalRows(){
  const rows:Record<string,unknown>[]=[];
  let assetNumber=0;
  for(let modulePosition=1;modulePosition<=9;modulePosition+=1){
    for(let lessonPosition=1;lessonPosition<=2;lessonPosition+=1){
      const slotCount=modulePosition===1&&lessonPosition===1?40:0;
      const imageSlots=Array.from({length:slotCount},()=>{
        assetNumber+=1;
        return{asset_key:`asset-${assetNumber}`,placement:"reference",slot_position:assetNumber,expected_alt_i18n:localized,media_id:null,width:null,height:null};
      });
      const contentSlots=imageSlots.map(slot=>({asset_key:slot.asset_key,placement:slot.placement,slot_position:slot.slot_position,label:"Image"}));
      const content={content_schema_version:1,layout:"photo_first",mode:lessonPosition===1?"reference":"procedure",items:[{fact_key:`fact-${modulePosition}-${lessonPosition}`,presentation:"overview",position:1,text:"Text",provenance_classification:"existing_training_supporting"}],...((modulePosition===3||modulePosition===5)&&lessonPosition===1?{}:{image_slots:contentSlots})};
      rows.push({
        course_id:uuid(10),course_version_id:uuid(11),version_number:1,version_status:"draft",revision:2,default_locale:"en",supported_locales:["en","ar","id","hi","fil"],course_title_i18n:localized,course_description_i18n:localized,
        module_id:uuid(100+modulePosition),module_key:moduleKeys[modulePosition-1],module_position:modulePosition,module_title_i18n:localized,module_description_i18n:localized,
        lesson_id:uuid(1000+modulePosition*10+lessonPosition),lesson_key:lessonPosition===1?"overview":"practical-photo-guide",lesson_position:lessonPosition,lesson_type:lessonPosition===1?"reading":"key_points",required:true,lesson_title_i18n:localized,lesson_objective_i18n:localized,lesson_content_i18n:{en:content,ar:content,id:content,hi:content,fil:content},question_count:null,pass_threshold_bps:null,image_slots:imageSlots,
      });
    }
  }
  rows.push({
    course_id:uuid(10),course_version_id:uuid(11),version_number:1,version_status:"draft",revision:2,default_locale:"en",supported_locales:["en","ar","id","hi","fil"],course_title_i18n:localized,course_description_i18n:localized,
    module_id:uuid(110),module_key:"final-assessment",module_position:10,module_title_i18n:localized,module_description_i18n:localized,
    lesson_id:uuid(1101),lesson_key:"final-quiz",lesson_position:1,lesson_type:"quiz",required:true,lesson_title_i18n:localized,lesson_objective_i18n:localized,lesson_content_i18n:null,question_count:27,pass_threshold_bps:8000,image_slots:[],
  });
  return rows;
}

function mockPostgrest(payload:unknown,status=200){
  globalThis.fetch=async()=>new Response(JSON.stringify(payload),{status,headers:{"content-type":"application/json"}});
  return createTrainingEmployeePreviewService("https://supabase.invalid","service-role-test");
}

describe("Training employee preview diagnostics",()=>{
  it("accepts the production-shaped nineteen rows and normalizes both zero-photo overviews in every locale",async()=>{
    const result=await mockPostgrest(canonicalRows()).getPreview(identity) as {instructional_modules:{stable_key:string;position:number;lessons:{stable_key:string;content_i18n:Record<string,{image_slots:unknown[]}>;images:unknown[]}[]}[];final_assessment:{question_count:number}};
    assert.equal(result.instructional_modules.length,9);
    assert.equal(result.instructional_modules.flatMap(module=>module.lessons).length,18);
    assert.equal(result.instructional_modules.flatMap(module=>module.lessons).flatMap(lesson=>lesson.images).length,40);
    assert.equal(result.final_assessment.question_count,27);
    for(const moduleKey of ["contamination-foodborne-illness-prevention","food-receiving"]){
      const overview=result.instructional_modules.find(module=>module.stable_key===moduleKey)?.lessons.find(lesson=>lesson.stable_key==="overview");
      assert.ok(overview);
      for(const locale of ["en","ar","id","hi","fil"])assert.deepEqual(overview.content_i18n[locale]?.image_slots,[]);
    }
  });

  it("rejects null, string, and object image_slots instead of treating them as absent",async()=>{
    for(const invalid of [null,"not-an-array",{}]){
      const rows=canonicalRows();
      const content=(rows[4]?.lesson_content_i18n as Record<string,Record<string,unknown>>);
      content.en={...content.en,image_slots:invalid};
      await assert.rejects(mockPostgrest(rows).getPreview(identity),(error:unknown)=>{
        const diagnostic=getTrainingEmployeePreviewDiagnostic(error,"preview_rpc");
        assert.equal(diagnostic.failureStage,"response_parse");
        assert.equal(diagnostic.safeCategory,"schema_validation");
        assert.deepEqual(diagnostic.issues?.[0]?.path,[4,"lesson_content_i18n","en","image_slots"]);
        return true;
      });
    }
  });

  it("keeps localized content strict and rejects unexpected keys",async()=>{
    const rows=canonicalRows();
    const content=(rows[4]?.lesson_content_i18n as Record<string,Record<string,unknown>>);
    content.en={...content.en,unexpected_key:"not allowed"};
    await assert.rejects(mockPostgrest(rows).getPreview(identity),(error:unknown)=>{
      const diagnostic=getTrainingEmployeePreviewDiagnostic(error,"preview_rpc");
      assert.equal(diagnostic.safeCategory,"schema_validation");
      assert.deepEqual(diagnostic.issues,[{code:"unrecognized_keys",path:[4,"lesson_content_i18n","en"]}]);
      return true;
    });
  });

  it("still rejects a missing binding for a lesson with declared photo slots",async()=>{
    const rows=canonicalRows();
    rows[0]={...rows[0],image_slots:[]};
    await assert.rejects(mockPostgrest(rows).getPreview(identity),(error:unknown)=>{
      assert.ok(error instanceof TrainingEmployeePreviewConflictError);
      assert.deepEqual(getTrainingEmployeePreviewDiagnostic(error,"preview_rpc"),{failureStage:"structure_validation",safeCategory:"contract_conflict"});
      return true;
    });
  });

  it("classifies a missing PostgREST signature without retaining raw error text",async()=>{
    const service=mockPostgrest({code:"PGRST202",message:"sensitive upstream detail",details:null,hint:null},404);
    await assert.rejects(service.getPreview(identity),(error:unknown)=>{
      assert.ok(error instanceof TrainingEmployeePreviewUnavailableError);
      assert.deepEqual(getTrainingEmployeePreviewDiagnostic(error,"session_validation"),{failureStage:"preview_rpc",safeCategory:"rpc_not_found",upstreamCode:"PGRST202"});
      assert.doesNotMatch(JSON.stringify(error),/sensitive upstream detail/);
      return true;
    });
  });

  it("recognizes only allowlisted dependency and not-found upstream codes",async()=>{
    for(const upstreamCode of ["42883","42P01","42703"]){
      await assert.rejects(mockPostgrest({code:upstreamCode,message:"raw dependency detail"},500).getPreview(identity),(error:unknown)=>{
        assert.deepEqual(getTrainingEmployeePreviewDiagnostic(error,"session_validation"),{failureStage:"preview_rpc",safeCategory:"rpc_dependency",upstreamCode});
        return true;
      });
    }
    await assert.rejects(mockPostgrest({code:"P0002",message:"raw missing detail"},404).getPreview(identity),(error:unknown)=>{
      assert.deepEqual(getTrainingEmployeePreviewDiagnostic(error,"session_validation"),{failureStage:"preview_rpc",safeCategory:"not_found",upstreamCode:"P0002"});
      return true;
    });
    await assert.rejects(mockPostgrest({code:"UNSAFE_CODE",message:"raw unknown detail"},500).getPreview(identity),(error:unknown)=>{
      assert.deepEqual(getTrainingEmployeePreviewDiagnostic(error,"session_validation"),{failureStage:"preview_rpc",safeCategory:"upstream_error"});
      assert.doesNotMatch(JSON.stringify(error),/UNSAFE_CODE|raw unknown detail/);
      return true;
    });
  });

  it("distinguishes invalid RPC results from strict schema parsing failures",async()=>{
    const malformed=mockPostgrest({rows:canonicalRows()});
    await assert.rejects(malformed.getPreview(identity),(error:unknown)=>{
      assert.deepEqual(getTrainingEmployeePreviewDiagnostic(error,"preview_rpc"),{failureStage:"response_parse",safeCategory:"invalid_result"});
      return true;
    });

    const rows=canonicalRows();
    rows[0]={...rows[0],unexpected_property:"must not be logged"};
    const parserFailure=mockPostgrest(rows);
    await assert.rejects(parserFailure.getPreview(identity),(error:unknown)=>{
      const diagnostic=getTrainingEmployeePreviewDiagnostic(error,"preview_rpc");
      assert.equal(diagnostic.failureStage,"response_parse");
      assert.equal(diagnostic.safeCategory,"schema_validation");
      assert.equal(diagnostic.issueCount,1);
      assert.deepEqual(diagnostic.issues,[{code:"unrecognized_keys",path:[0]}]);
      assert.doesNotMatch(JSON.stringify(diagnostic),/must not be logged/);
      return true;
    });
  });

  it("distinguishes structural conflicts and preserves authorization/status mappings",async()=>{
    const rows=canonicalRows();
    rows[2]={...rows[2],module_id:rows[0]?.module_id};
    await assert.rejects(mockPostgrest(rows).getPreview(identity),(error:unknown)=>{
      assert.ok(error instanceof TrainingEmployeePreviewConflictError);
      assert.deepEqual(getTrainingEmployeePreviewDiagnostic(error,"preview_rpc"),{failureStage:"structure_validation",safeCategory:"contract_conflict"});
      return true;
    });

    await assert.rejects(mockPostgrest({code:"42501",message:"denied"},403).getPreview(identity),TrainingEmployeePreviewAccessError);
    await assert.rejects(mockPostgrest({code:"55000",message:"changed"},409).getPreview(identity),(error:unknown)=>{
      assert.ok(error instanceof TrainingEmployeePreviewConflictError);
      assert.deepEqual(getTrainingEmployeePreviewDiagnostic(error,"preview_rpc"),{failureStage:"preview_rpc",safeCategory:"contract_conflict",upstreamCode:"55000"});
      return true;
    });
  });
});
