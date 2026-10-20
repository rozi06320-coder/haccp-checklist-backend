import assert from "node:assert/strict";
import {generateKeyPairSync} from "node:crypto";
import {describe,it} from "node:test";
import {verifyTrainingPublicationAuthorization,type TrainingPublicationAuthorization} from "./training-publication-authorization";
import {createTrainingPublicationServiceFromClient,TrainingPublicationUnavailableError} from "./training-publication";

const ids={actor:"ba000000-0000-4000-8000-000000000001",organization:"ba000000-0000-4000-8000-000000000002",course:"ba000000-0000-4000-8000-000000000003",version:"ba000000-0000-4000-8000-000000000004",submission:"ba000000-0000-4000-8000-000000000005",run:"ba000000-0000-4000-8000-000000000006",nonce:"ba000000-0000-4000-8000-000000000007",action:"ba000000-0000-4000-8000-000000000008",request:"ba000000-0000-4000-8000-000000000009"};
const fingerprint="b".repeat(64),scope={actorUserId:ids.actor,organizationId:ids.organization,courseId:ids.course,courseVersionId:ids.version};

describe("Training publication signed job service",()=>{
  it("signs only the server-fetched nonce/timestamps and exact authenticated scope",async()=>{
    const pair=generateKeyPairSync("ed25519"),privateKeyPem=pair.privateKey.export({format:"pem",type:"pkcs8"}).toString(),publicKeyPem=pair.publicKey.export({format:"pem",type:"spki"}).toString();let queued:Record<string,unknown>|undefined;
    const client={async rpc(name:string,args:Record<string,unknown>){
      if(name==="get_internal_admin_training_publication_signing_context")return{data:[{challenge_nonce:ids.nonce,issued_at_epoch_seconds:1792324800,expires_at_epoch_seconds:1792325400}],error:null};
      if(name==="request_internal_admin_training_publication"){queued=args;return{data:[{publication_request_id:ids.request,verification_run_id:ids.run,requested_at:"2026-10-18T12:00:00Z"}],error:null};}
      throw new Error("unexpected RPC");
    }};
    const service=createTrainingPublicationServiceFromClient(client,{privateKeyPem,audience:"haccp.production.training-publication",keyId:"publication-2026-10"});
    await service.requestPublication(scope,{submissionId:ids.submission,verificationRunId:ids.run,expectedRevision:2,contentFingerprint:fingerprint,requestId:ids.action});
    const envelope=queued?.signed_authorization_envelope as TrainingPublicationAuthorization,signature=queued?.authorization_signature as string;
    assert.deepEqual(envelope,{protocol_version:1,audience:"haccp.production.training-publication",key_id:"publication-2026-10",actor_user_id:ids.actor,organization_id:ids.organization,course_id:ids.course,course_version_id:ids.version,submission_id:ids.submission,verification_run_id:ids.run,challenge_nonce:ids.nonce,issued_at_epoch_seconds:1792324800,expires_at_epoch_seconds:1792325400,expected_revision:2,expected_content_fingerprint:fingerprint,action_request_id:ids.action});
    assert.equal(verifyTrainingPublicationAuthorization(envelope,signature,publicKeyPem),true);
  });
  it("fails closed before any RPC when the signing triplet is incomplete",async()=>{
    let calls=0;const service=createTrainingPublicationServiceFromClient({async rpc(){calls+=1;return{data:null,error:null};}},{audience:"haccp.production.training-publication"});
    await assert.rejects(()=>service.requestPublication(scope,{submissionId:ids.submission,verificationRunId:ids.run,expectedRevision:2,contentFingerprint:fingerprint,requestId:ids.action}),TrainingPublicationUnavailableError);
    assert.equal(calls,0);
  });
});
