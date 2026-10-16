import assert from "node:assert/strict";
import { describe,it } from "node:test";
import sharp from "sharp";
import { createTrainingMediaServiceFromClient,MAX_TRAINING_MEDIA_SOURCE_BYTES,trainingImageSlotRowSchema,TrainingMediaConflictError,TrainingMediaInputError,TrainingMediaUnavailableError } from "./training-media";

const actor="11111111-1111-4111-8111-111111111111",organization="22222222-2222-4222-8222-222222222222",course="33333333-3333-4333-8333-333333333333",version="44444444-4444-4444-8444-444444444444";
const scope={actorUserId:actor,organizationId:organization,courseId:course,courseVersionId:version,requestId:"request"};
const i18n={en:"Clean hands",ar:"أيدٍ نظيفة",id:"Tangan bersih",hi:"साफ हाथ",fil:"Malinis na kamay"};
const metadata={asset_key:"handwashing-step-01",title_i18n:i18n,alt_i18n:i18n};
async function image(format:"jpeg"|"png"|"webp",options:Record<string,unknown>={}){let value=sharp({create:{width:1280,height:720,channels:4,background:{r:10,g:20,b:30,alpha:0.5}}});if(options.orientation)value=value.withMetadata({orientation:Number(options.orientation)});return format==="jpeg"?value.jpeg().toBuffer():format==="png"?value.png().toBuffer():value.webp().toBuffer();}
function fixture(options:{uploadError?:boolean;registerError?:boolean;replaceError?:boolean;removeError?:boolean}={}){
 const uploads:Array<{path:string;bytes:Buffer;options:Record<string,unknown>}>=[],removed:string[][]=[];
 let current:Record<string,unknown>|null=null;
 const storage={upload:async(path:string,bytes:Buffer,uploadOptions:Record<string,unknown>)=>{uploads.push({path,bytes,options:uploadOptions});return{data:options.uploadError?null:{path},error:options.uploadError?{}:null};},remove:async(paths:string[])=>{removed.push(paths);return{data:null,error:options.removeError?{}:null};},download:async()=>({data:null,error:{}}),createSignedUrl:async()=>({data:{signedUrl:"https://signed.invalid/read"},error:null})};
 const client={storage:{from:()=>storage},rpc:async(name:string,args:Record<string,unknown>={})=>{
  if(name==="register_internal_admin_training_media"){current={id:args.target_media_id,asset_key:args.target_asset_key,media_type:"image",title_i18n:args.new_title_i18n,alt_i18n:args.new_alt_i18n,mime_type:"image/webp",byte_size:args.new_byte_size,width:args.new_width,height:args.new_height,approval_status:"submitted",status:"ready",created_at:"2026-10-14T00:00:00Z",updated_at:"2026-10-14T00:00:00Z",revision:1,reviewed_at:null,rejection_reason:null};return options.registerError?{data:null,error:{code:"XX000"}}:{data:[current],error:null};}
  if(name==="replace_internal_admin_training_media"){if(options.replaceError)return{data:null,error:{code:"XX000"}};current={id:args.target_media_id,asset_key:metadata.asset_key,media_type:"image",title_i18n:args.new_title_i18n,alt_i18n:args.new_alt_i18n,mime_type:"image/webp",byte_size:args.new_byte_size,width:args.new_width,height:args.new_height,approval_status:"submitted",status:"ready",created_at:"2026-10-14T00:00:00Z",updated_at:"2026-10-14T00:00:01Z",revision:2,reviewed_at:null,rejection_reason:null};return{data:[{id:args.target_media_id,old_storage_object_path:"old/object.webp",storage_object_path:args.new_storage_object_path}],error:null};}
  if(name==="list_internal_admin_training_media")return{data:current?[current]:[],error:null};
  return{data:[],error:null};
 }};
 return{service:createTrainingMediaServiceFromClient(client as never),uploads,removed};
}
describe("Training media normalization and lifecycle",()=>{
 for(const [format,mime] of [["jpeg","image/jpeg"],["png","image/png"],["webp","image/webp"]] as const)it(`accepts ${format}, strips metadata, and stores WebP`,async()=>{
  const test=fixture(),source=await image(format);const saved=await test.service.create(scope,{...metadata,bytes:source,declaredMime:mime});
  assert.equal(saved.mime_type,"image/webp");assert.equal(saved.width,1280);assert.equal(saved.height,720);assert.equal(test.uploads.length,1);assert.equal(test.uploads[0].options.contentType,"image/webp");
  const decoded=await sharp(test.uploads[0].bytes).metadata();assert.equal(decoded.format,"webp");assert.equal(decoded.exif,undefined);assert.equal(decoded.icc,undefined);
 });
 it("rejects SVG, GIF, HEIC, AVIF, PDF and MIME mismatches",async()=>{const test=fixture(),jpeg=await image("jpeg");for(const [bytes,mime] of [[Buffer.from("<svg/>"),"image/svg+xml"],[Buffer.from("GIF89a"),"image/gif"],[Buffer.from("ftypheic"),"image/heic"],[Buffer.from("ftypavif"),"image/avif"],[Buffer.from("%PDF"),"application/pdf"],[jpeg,"image/png"]] as const)await assert.rejects(()=>test.service.create(scope,{...metadata,bytes,declaredMime:mime}),TrainingMediaInputError);assert.equal(test.uploads.length,0);});
 it("rejects malformed, oversized, and undersized input",async()=>{const test=fixture();await assert.rejects(()=>test.service.create(scope,{...metadata,bytes:Buffer.from([0xff,0xd8,0xff]),declaredMime:"image/jpeg"}),TrainingMediaInputError);await assert.rejects(()=>test.service.create(scope,{...metadata,bytes:Buffer.alloc(MAX_TRAINING_MEDIA_SOURCE_BYTES+1),declaredMime:"image/jpeg"}),TrainingMediaInputError);const small=await sharp({create:{width:300,height:200,channels:3,background:"white"}}).png().toBuffer();await assert.rejects(()=>test.service.create(scope,{...metadata,bytes:small,declaredMime:"image/png"}),TrainingMediaInputError);});
 it("rejects compressed images over the decoded pixel limit",async()=>{const test=fixture(),bomb=await sharp({create:{width:8000,height:6000,channels:3,background:"white"}}).png({compressionLevel:9}).toBuffer();assert.ok(bomb.length<MAX_TRAINING_MEDIA_SOURCE_BYTES);await assert.rejects(()=>test.service.create(scope,{...metadata,bytes:bomb,declaredMime:"image/png"}),TrainingMediaInputError);});
 it("normalizes orientation and caps the long edge without upscaling",async()=>{const oriented=fixture(),source=await image("jpeg",{orientation:6});const rotated=await oriented.service.create(scope,{...metadata,bytes:source,declaredMime:"image/jpeg"});assert.equal(rotated.width,720);assert.equal(rotated.height,1280);const resizedFixture=fixture(),large=await sharp({create:{width:3000,height:1800,channels:3,background:"white"}}).jpeg().toBuffer();const resized=await resizedFixture.service.create(scope,{...metadata,bytes:large,declaredMime:"image/jpeg"});assert.equal(resized.width,2560);assert.equal(resized.height,1536);});
 it("removes a write-once object when DB registration fails",async()=>{const test=fixture({registerError:true}),source=await image("png");await assert.rejects(()=>test.service.create(scope,{...metadata,bytes:source,declaredMime:"image/png"}),TrainingMediaUnavailableError);assert.equal(test.uploads.length,1);assert.deepEqual(test.removed,[[test.uploads[0].path]]);});
 it("leaves no DB attempt when Storage upload fails",async()=>{const test=fixture({uploadError:true}),source=await image("png");await assert.rejects(()=>test.service.create(scope,{...metadata,bytes:source,declaredMime:"image/png"}),TrainingMediaUnavailableError);assert.equal(test.removed.length,0);});
 it("replaces through a new object, commits metadata, then removes the old object",async()=>{const test=fixture(),source=await image("jpeg");const saved=await test.service.replace(scope,{assetId:"55555555-5555-4555-8555-555555555555",...metadata,bytes:source,declaredMime:"image/jpeg"});assert.equal(saved.asset_key,metadata.asset_key);assert.equal(test.uploads.length,1);assert.deepEqual(test.removed,[["old/object.webp"]]);});
 it("keeps the old object and compensates the new object when replacement DB swap fails",async()=>{const test=fixture({replaceError:true}),source=await image("png");await assert.rejects(()=>test.service.replace(scope,{assetId:"55555555-5555-4555-8555-555555555555",...metadata,bytes:source,declaredMime:"image/png"}),TrainingMediaUnavailableError);assert.deepEqual(test.removed,[[test.uploads[0].path]]);});
 it("keeps a successful replacement when old-object cleanup fails",async()=>{const test=fixture({removeError:true}),source=await image("webp");const saved=await test.service.replace(scope,{assetId:"55555555-5555-4555-8555-555555555555",...metadata,bytes:source,declaredMime:"image/webp"});assert.equal(saved.status,"ready");assert.deepEqual(test.removed,[["old/object.webp"]]);});
});

describe("Training required image slot DTO",()=>{
 const row={module_id:"55555555-5555-4555-8555-555555555551",module_key:"personal-hygiene-health",module_position:1,module_title_i18n:i18n,lesson_id:"55555555-5555-4555-8555-555555555552",lesson_key:"practical-photo-guide",lesson_position:2,lesson_title_i18n:i18n,asset_key:"personal-hygiene-handwashing-wet",placement:"procedure-step",purpose_i18n:i18n,expected_alt_i18n:i18n,media_alt_i18n:i18n,media_id:"55555555-5555-4555-8555-555555555553",media_status:"ready" as const,approval_status:"submitted" as const,width:1280,height:720,preview_available:true,revision:1,reviewed_at:null,rejection_reason:null};
 it("is strict and cannot parse storage details",()=>{assert.throws(()=>trainingImageSlotRowSchema.parse({...row,storage_object_path:"private/object.webp"}));});
 it("preserves RPC order and adds only a same-origin preview route",async()=>{
  const client={storage:{from:()=>({upload:async()=>({data:null,error:null}),remove:async()=>({data:null,error:null}),download:async()=>({data:null,error:null}),createSignedUrl:async()=>({data:null,error:null})})},rpc:async(name:string)=>({data:name==="list_internal_admin_training_image_slots"?[row,{...row,asset_key:"personal-hygiene-handwashing-soap",media_alt_i18n:null,media_id:null,media_status:null,approval_status:null,width:null,height:null,preview_available:false,revision:null,reviewed_at:null,rejection_reason:null}]:[],error:null})};
  const slots=await createTrainingMediaServiceFromClient(client as never).listSlots(scope);
  assert.deepEqual(slots.map(slot=>slot.asset_key),["personal-hygiene-handwashing-wet","personal-hygiene-handwashing-soap"]);
  assert.match(slots[0].preview_url??"",/^\/api\/internal-admin\/training\/media\//);
  assert.equal(slots[1].preview_url,null);
  assert.equal("storage_object_path" in slots[0],false);
 });
});

describe("Training media review lifecycle",()=>{
 it("verifies unchanged private Storage bytes before approval",async()=>{
  const bytes=await image("webp"),sha256=(await import("node:crypto")).createHash("sha256").update(bytes).digest("hex");
  let downloads=0,uploads=0;const calls:Array<{name:string;args:Record<string,unknown>}>=[];
  const client={storage:{from:()=>({upload:async()=>{uploads+=1;return{data:null,error:null};},remove:async()=>({data:null,error:null}),download:async()=>{downloads+=1;return{data:new Blob([bytes]),error:null};},createSignedUrl:async()=>({data:null,error:null})})},rpc:async(name:string,args:Record<string,unknown>={})=>{
   calls.push({name,args});
   if(name==="get_internal_admin_training_media_review_candidate")return{data:[{storage_bucket:"training-media",storage_object_path:"private/object.webp",mime_type:"image/webp",byte_size:bytes.length,width:1280,height:720,sha256,revision:4,approval_status:"submitted",status:"ready"}],error:null};
   if(name==="review_internal_admin_training_media")return{data:[{id:"55555555-5555-4555-8555-555555555555",approval_status:"approved",reviewed_at:"2026-10-16T12:00:00Z",rejection_reason:null,revision:5,updated_at:"2026-10-16T12:00:00Z"}],error:null};
   return{data:[],error:null};
  }};
  const result=await createTrainingMediaServiceFromClient(client as never).review(scope,{assetId:"55555555-5555-4555-8555-555555555555",revision:4,decision:"approved"});
  assert.equal(result.approval_status,"approved");assert.equal(downloads,1);assert.equal(uploads,0);
  assert.equal(calls.at(-1)?.args.expected_revision,4);assert.equal(calls.at(-1)?.args.review_decision,"approved");
 });
 it("rejects a changed object and never commits approval",async()=>{
  const bytes=await image("webp");let reviewCalls=0;
  const client={storage:{from:()=>({upload:async()=>({data:null,error:null}),remove:async()=>({data:null,error:null}),download:async()=>({data:new Blob([bytes]),error:null}),createSignedUrl:async()=>({data:null,error:null})})},rpc:async(name:string)=>{
   if(name==="get_internal_admin_training_media_review_candidate")return{data:[{storage_bucket:"training-media",storage_object_path:"private/object.webp",mime_type:"image/webp",byte_size:bytes.length,width:1280,height:720,sha256:"0".repeat(64),revision:1,approval_status:"submitted",status:"ready"}],error:null};
   if(name==="review_internal_admin_training_media")reviewCalls+=1;return{data:[],error:null};
  }};
  await assert.rejects(()=>createTrainingMediaServiceFromClient(client as never).review(scope,{assetId:"55555555-5555-4555-8555-555555555555",revision:1,decision:"approved"}),TrainingMediaConflictError);
  assert.equal(reviewCalls,0);
 });
 it("records rejection without reading or modifying image bytes",async()=>{
  let storageCalls=0;
  const client={storage:{from:()=>({upload:async()=>{storageCalls+=1;return{data:null,error:null};},remove:async()=>{storageCalls+=1;return{data:null,error:null};},download:async()=>{storageCalls+=1;return{data:null,error:null};},createSignedUrl:async()=>({data:null,error:null})})},rpc:async(name:string,args:Record<string,unknown>={})=>{
   if(name==="get_internal_admin_training_media_review_candidate")return{data:[{storage_bucket:"training-media",storage_object_path:"private/object.webp",mime_type:"image/webp",byte_size:10,width:1280,height:720,sha256:"a".repeat(64),revision:2,approval_status:"submitted",status:"ready"}],error:null};
   if(name==="review_internal_admin_training_media")return{data:[{id:"55555555-5555-4555-8555-555555555555",approval_status:"rejected",reviewed_at:"2026-10-16T12:00:00Z",rejection_reason:args.new_rejection_reason,revision:3,updated_at:"2026-10-16T12:00:00Z"}],error:null};
   return{data:[],error:null};
  }};
  const result=await createTrainingMediaServiceFromClient(client as never).review(scope,{assetId:"55555555-5555-4555-8555-555555555555",revision:2,decision:"rejected",rejectionReason:"Operational subject is unclear."});
  assert.equal(result.rejection_reason,"Operational subject is unclear.");assert.equal(storageCalls,0);
 });
});
