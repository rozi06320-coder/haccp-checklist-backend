import assert from "node:assert/strict";
import {createHash,generateKeyPairSync} from "node:crypto";
import {describe,it} from "node:test";
import sharp from "sharp";
import {signTrainingPublicationAuthorization,verifyTrainingPublicationAuthorization,type TrainingPublicationAuthorization} from "./training-publication-authorization";
import {createTrainingVerifierStorage,processTrainingVerifierJob,TrainingVerifierRejectedError,TrainingVerifierUnavailableError,type TrainingVerifierDatabase,type TrainingVerifierJobRow} from "./training-storage-verifier";

const ids={actor:"a1000000-0000-4000-8000-000000000001",organization:"a2000000-0000-4000-8000-000000000001",course:"a3000000-0000-4000-8000-000000000001",version:"a4000000-0000-4000-8000-000000000001",submission:"a5000000-0000-4000-8000-000000000001",run:"a6000000-0000-4000-8000-000000000001",request:"a7000000-0000-4000-8000-000000000001",action:"a8000000-0000-4000-8000-000000000001",nonce:"a9000000-0000-4000-8000-000000000001",lease:"aa000000-0000-4000-8000-000000000001"};
const keys=generateKeyPairSync("ed25519"),privateKey=keys.privateKey.export({format:"pem",type:"pkcs8"}).toString(),publicKey=keys.publicKey.export({format:"pem",type:"spki"}).toString();
const envelope:TrainingPublicationAuthorization={protocol_version:1,audience:"haccp.production.training-publication",key_id:"publication-2026-10",actor_user_id:ids.actor,organization_id:ids.organization,course_id:ids.course,course_version_id:ids.version,submission_id:ids.submission,verification_run_id:ids.run,challenge_nonce:ids.nonce,issued_at_epoch_seconds:1792324800,expires_at_epoch_seconds:1792325400,expected_revision:2,expected_content_fingerprint:"a".repeat(64),action_request_id:ids.action};
const verifierKeys={audience:envelope.audience,publicKeysById:{[envelope.key_id]:publicKey}};

async function fixture(overrides:Partial<TrainingVerifierJobRow>={}){
  const bytes=await sharp({create:{width:1280,height:720,channels:3,background:"white"}}).webp().toBuffer();
  const digest=createHash("sha256").update(bytes).digest("hex"),signature=signTrainingPublicationAuthorization(envelope,privateKey);
  const rows=Array.from({length:40},(_,index)=>{const mediaId=`${String(index+100).padStart(8,"0")}-0000-4000-8000-000000000001`;return{publication_request_id:ids.request,lease_token:ids.lease,lease_expires_at:new Date("2026-10-18T12:05:00Z"),authorization_envelope:envelope,authorization_signature:signature,media_id:mediaId,media_revision:2,storage_bucket:"training-media" as const,storage_object_path:`organizations/${ids.organization}/courses/${ids.course}/versions/${ids.version}/assets/${mediaId}/b0000000-0000-4000-8000-000000000001.webp`,expected_sha256:digest,expected_byte_size:bytes.length,expected_width:1280,expected_height:720,...overrides};});
  return{bytes,rows};
}
function database(rows:TrainingVerifierJobRow[]){let claimed=false;const failures:{code:string;retryable:boolean}[]=[],blocks:number[]=[];const value:TrainingVerifierDatabase={
  async claim(){if(claimed)return[];claimed=true;return rows;},
  async fail(_id,_lease,code,retryable){failures.push({code,retryable});},
  async blockAfterSourceVerification(_id,_lease,observations){blocks.push(observations.length);},
};return{value,failures,blocks};}
const now=()=>new Date("2026-10-18T12:00:00Z");

describe("trusted Training Storage verifier",()=>{
  it("streams, verifies all forty exact source objects, then fail-closes publication",async()=>{
    const test=await fixture(),db=database(test.rows);let downloads=0;
    assert.equal(await processTrainingVerifierJob(db.value,{async download(){downloads+=1;return{bytes:test.bytes,mimeType:"image/webp"};}},verifierKeys,now),true);
    assert.equal(downloads,40);assert.deepEqual(db.blocks,[40]);assert.deepEqual(db.failures,[]);
  });
  it("rejects forged, non-canonical, replayed, and cross-environment authorizations before Storage",async()=>{
    const variants=[
      {authorization_signature:Buffer.alloc(64).toString("base64")},
      {authorization_envelope:{...envelope,audience:"haccp.staging.training-publication"}},
      {authorization_envelope:{...envelope,challenge_nonce:"a9000000-0000-4000-8000-000000000002"}},
    ];
    for(const variant of variants){const test=await fixture(variant as Partial<TrainingVerifierJobRow>),db=database(test.rows);let downloads=0;
      await assert.rejects(()=>processTrainingVerifierJob(db.value,{async download(){downloads+=1;return{bytes:test.bytes,mimeType:"image/webp"};}},verifierKeys,now),TrainingVerifierRejectedError);
      assert.equal(downloads,0);assert.deepEqual(db.failures,[{code:"source_verification_rejected",retryable:false}]);}
    assert.equal(verifyTrainingPublicationAuthorization(envelope,signTrainingPublicationAuthorization(envelope,privateKey).replace(/==$/,"AA"),publicKey),false);
  });
  it("requires Ed25519 signing keys and supports explicit key-id rotation",()=>{
    const rsa=generateKeyPairSync("rsa",{modulusLength:2048}).privateKey.export({format:"pem",type:"pkcs8"}).toString();
    assert.throws(()=>signTrainingPublicationAuthorization(envelope,rsa),/Ed25519/);
    assert.equal(signTrainingPublicationAuthorization(envelope,privateKey).length,88);
  });
  it("rejects changed bytes, digest, dimensions, MIME, path, and fewer than forty slots",async()=>{
    for(const change of [
      async(test:Awaited<ReturnType<typeof fixture>>)=>({rows:test.rows,bytes:Buffer.from("changed"),mimeType:"image/webp"}),
      async(test:Awaited<ReturnType<typeof fixture>>)=>({rows:test.rows.map(row=>({...row,expected_sha256:"0".repeat(64)})),bytes:test.bytes,mimeType:"image/webp"}),
      async(test:Awaited<ReturnType<typeof fixture>>)=>({rows:test.rows.map(row=>({...row,expected_width:1279})),bytes:test.bytes,mimeType:"image/webp"}),
      async(test:Awaited<ReturnType<typeof fixture>>)=>({rows:test.rows,bytes:test.bytes,mimeType:"image/png"}),
      async(test:Awaited<ReturnType<typeof fixture>>)=>({rows:test.rows.map(row=>({...row,storage_object_path:"organizations/wrong/object.webp"})),bytes:test.bytes,mimeType:"image/webp"}),
      async(test:Awaited<ReturnType<typeof fixture>>)=>({rows:test.rows.slice(0,39),bytes:test.bytes,mimeType:"image/webp"}),
    ]){const test=await fixture(),changed=await change(test),db=database(changed.rows);
      await assert.rejects(()=>processTrainingVerifierJob(db.value,{async download(){return{bytes:changed.bytes,mimeType:changed.mimeType};}},verifierKeys,now),TrainingVerifierRejectedError);
      assert.equal(db.blocks.length,0);}
  });
  it("makes a claimed job one-shot and bounds concurrent downloads to two",async()=>{
    const test=await fixture(),db=database(test.rows);let active=0,maxActive=0;
    const storage={async download(){active+=1;maxActive=Math.max(maxActive,active);await Promise.resolve();active-=1;return{bytes:test.bytes,mimeType:"image/webp"};}};
    assert.equal(await processTrainingVerifierJob(db.value,storage,verifierKeys,now),true);
    assert.equal(await processTrainingVerifierJob(db.value,storage,verifierKeys,now),false);assert.ok(maxActive<=2);
  });
  it("streams with a byte cap, fixed origin, redirect rejection, and cancellation timeout",async()=>{
    const original=globalThis.fetch;
    try{
      globalThis.fetch=async()=>new Response(new Uint8Array(1),{headers:{"content-length":String(6*1024*1024),"content-type":"image/webp"}});
      const oversized=createTrainingVerifierStorage({url:"https://storage.example.invalid",publishableKey:"public",accessToken:"token".repeat(8),timeoutMs:1000});
      await assert.rejects(()=>oversized.download("training-media","safe/object.webp"),TrainingVerifierRejectedError);
      globalThis.fetch=async(_input,init)=>new Promise<Response>((_resolve,reject)=>init?.signal?.addEventListener("abort",()=>reject(new Error("aborted"))));
      const timed=createTrainingVerifierStorage({url:"https://storage.example.invalid",publishableKey:"public",accessToken:"token".repeat(8),timeoutMs:5});
      await assert.rejects(()=>timed.download("training-media","safe/object.webp"),TrainingVerifierUnavailableError);
      await assert.rejects(()=>timed.download("training-media","../escape.webp"),TrainingVerifierRejectedError);
    }finally{globalThis.fetch=original;}
  });
});
