import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { signTrainingPublicationAuthorization,TRAINING_PUBLICATION_PROTOCOL_VERSION,type TrainingPublicationAuthorization } from "./training-publication-authorization";

const uuid=z.uuid(),fingerprint=z.string().regex(/^[0-9a-f]{64}$/);
const scopeSchema=z.object({actorUserId:uuid,organizationId:uuid,courseId:uuid,courseVersionId:uuid}).strict();
const submissionRow=z.object({id:uuid,organization_id:uuid,course_id:uuid,course_version_id:uuid,version_revision:z.coerce.number().int().nonnegative(),content_fingerprint:fingerprint,submitted_by:uuid,action_request_id:uuid,submitted_at:z.string()}).passthrough();
const reviewRow=z.object({id:uuid,submission_id:uuid,review_type:z.enum(["content","translation","internal_regulatory"]),locale:z.enum(["en","ar","id","hi","fil"]).nullable(),decision:z.enum(["approved","rejected","revoked"]),actor_user_id:uuid,reason:z.string().nullable(),action_request_id:uuid,occurred_at:z.string()}).passthrough();
const verificationRow=z.object({verification_run_id:uuid,challenge_nonce:uuid,expires_at:z.string(),media_id:uuid,media_revision:z.number().int().positive(),storage_bucket:z.literal("training-media"),storage_object_path:z.string(),expected_sha256:fingerprint,expected_byte_size:z.number().int().positive(),expected_width:z.number().int().positive(),expected_height:z.number().int().positive()}).strict();
const publicationRequestRow=z.object({publication_request_id:uuid,verification_run_id:uuid,requested_at:z.string()}).strict();
const signingContextRow=z.object({challenge_nonce:uuid,issued_at_epoch_seconds:z.coerce.number().int().positive(),expires_at_epoch_seconds:z.coerce.number().int().positive()}).strict();
const historyRow=z.object({event_id:uuid,event_kind:z.enum(["submission","review","media_review","lifecycle","verifier"]),event_type:z.string(),review_type:z.string().nullable(),locale:z.string().nullable(),decision:z.string().nullable(),actor_id:uuid.nullable(),reason:z.string().nullable(),action_request_id:uuid,occurred_at:z.string(),version_revision:z.coerce.number().int().nonnegative().nullable(),content_fingerprint:z.string().nullable(),details:z.record(z.string(),z.unknown())}).strict();

export class TrainingPublicationAccessError extends Error{}
export class TrainingPublicationInputError extends Error{}
export class TrainingPublicationConflictError extends Error{}
export class TrainingPublicationNotFoundError extends Error{}
export class TrainingPublicationUnavailableError extends Error{}

type Scope=z.infer<typeof scopeSchema>;
type RpcClient={rpc:(name:string,args?:Record<string,unknown>)=>PromiseLike<{data:unknown;error:{code?:string}|null}>};
export type TrainingPublicationService={
  submit(scope:Scope,input:{expectedRevision:number;contentFingerprint:string;requestId:string}):Promise<z.infer<typeof submissionRow>>;
  review(scope:Scope,input:{submissionId:string;expectedRevision:number;contentFingerprint:string;reviewType:"content"|"translation"|"internal_regulatory";locale:"en"|"ar"|"id"|"hi"|"fil"|null;decision:"approved"|"rejected";reason:string|null;requestId:string}):Promise<z.infer<typeof reviewRow>>;
  revoke(scope:Scope,input:{submissionId:string;reviewType:"content"|"translation"|"internal_regulatory";locale:"en"|"ar"|"id"|"hi"|"fil"|null;reason:string;requestId:string}):Promise<z.infer<typeof reviewRow>>;
  history(scope:Scope):Promise<z.infer<typeof historyRow>[]>;
  beginVerification(scope:Scope,input:{submissionId:string;expectedRevision:number;contentFingerprint:string;requestId:string}):Promise<{verification_run_id:string;expires_at:string;object_count:40}>;
  requestPublication(scope:Scope,input:{submissionId:string;verificationRunId:string;expectedRevision:number;contentFingerprint:string;requestId:string}):Promise<z.infer<typeof publicationRequestRow>>;
  retireCourse(scope:Scope,input:{reason:string;requestId:string}):Promise<unknown>;
  activateProgram(actorUserId:string,organizationId:string,programId:string,requestId:string):Promise<unknown>;
  retireProgram(actorUserId:string,organizationId:string,programId:string,reason:string,requestId:string):Promise<unknown>;
};

const clientOptions={auth:{autoRefreshToken:false,detectSessionInUrl:false,persistSession:false}} as const;
type PublicationSigningConfig={privateKeyPem?:string;audience?:string;keyId?:string};
export function createTrainingPublicationService(url:string,secretKey:string,signing:PublicationSigningConfig={}){
  return createTrainingPublicationServiceFromClient(createClient(url,secretKey,clientOptions) as unknown as RpcClient,signing);
}

export function createTrainingPublicationServiceFromClient(client:RpcClient,signing:PublicationSigningConfig={}):TrainingPublicationService{
  async function rpc(name:string,args:Record<string,unknown>){const result=await client.rpc(name,args);if(result.error){
    if(result.error.code==="42501")throw new TrainingPublicationAccessError();
    if(result.error.code==="22023")throw new TrainingPublicationInputError();
    if(result.error.code==="40001"||result.error.code==="55000"||result.error.code==="23505")throw new TrainingPublicationConflictError();
    if(result.error.code==="P0002")throw new TrainingPublicationNotFoundError();
    throw new TrainingPublicationUnavailableError();
  }return result.data;}
  const base=(scope:Scope)=>({actor_user_id:scope.actorUserId,target_organization_id:scope.organizationId,target_course_id:scope.courseId,target_course_version_id:scope.courseVersionId});
  return{
    async submit(scope,input){scopeSchema.parse(scope);const rows=z.array(submissionRow).length(1).parse(await rpc("submit_internal_admin_training_version_for_review",{...base(scope),expected_revision:input.expectedRevision,expected_content_fingerprint:fingerprint.parse(input.contentFingerprint),action_request_id:uuid.parse(input.requestId)}));return rows[0]!;},
    async review(scope,input){scopeSchema.parse(scope);const rows=z.array(reviewRow).length(1).parse(await rpc("review_internal_admin_training_version",{...base(scope),target_submission_id:uuid.parse(input.submissionId),expected_revision:input.expectedRevision,expected_content_fingerprint:fingerprint.parse(input.contentFingerprint),target_review_type:input.reviewType,review_locale:input.locale,review_decision:input.decision,review_reason:input.reason,action_request_id:uuid.parse(input.requestId)}));return rows[0]!;},
    async revoke(scope,input){scopeSchema.parse(scope);const rows=z.array(reviewRow).length(1).parse(await rpc("revoke_internal_admin_training_version_approval",{...base(scope),target_submission_id:uuid.parse(input.submissionId),target_review_type:input.reviewType,review_locale:input.locale,revocation_reason:input.reason,action_request_id:uuid.parse(input.requestId)}));return rows[0]!;},
    async history(scope){scopeSchema.parse(scope);return z.array(historyRow).parse(await rpc("get_internal_admin_training_publication_history",base(scope)));},
    async beginVerification(scope,input){scopeSchema.parse(scope);const rows=z.array(verificationRow).length(40).parse(await rpc("begin_internal_admin_training_storage_verification",{...base(scope),target_submission_id:uuid.parse(input.submissionId),expected_revision:input.expectedRevision,expected_content_fingerprint:fingerprint.parse(input.contentFingerprint),action_request_id:uuid.parse(input.requestId)}));const first=rows[0]!;if(rows.some(row=>row.verification_run_id!==first.verification_run_id||row.expires_at!==first.expires_at)||new Set(rows.map(row=>row.media_id)).size!==40)throw new TrainingPublicationConflictError();return{verification_run_id:first.verification_run_id,expires_at:first.expires_at,object_count:40};},
    async requestPublication(scope,input){
      scopeSchema.parse(scope);
      if(!signing.privateKeyPem||!signing.audience||!signing.keyId)throw new TrainingPublicationUnavailableError();
      const submissionId=uuid.parse(input.submissionId),verificationRunId=uuid.parse(input.verificationRunId);
      const contentFingerprint=fingerprint.parse(input.contentFingerprint),actionRequestId=uuid.parse(input.requestId);
      const contextRows=z.array(signingContextRow).length(1).parse(await rpc(
        "get_internal_admin_training_publication_signing_context",
        {...base(scope),target_submission_id:submissionId,target_verification_run_id:verificationRunId,
          expected_revision:input.expectedRevision,expected_content_fingerprint:contentFingerprint},
      ));
      const context=contextRows[0]!;
      const envelope:TrainingPublicationAuthorization={
        protocol_version:TRAINING_PUBLICATION_PROTOCOL_VERSION,audience:signing.audience,key_id:signing.keyId,
        actor_user_id:scope.actorUserId,organization_id:scope.organizationId,course_id:scope.courseId,
        course_version_id:scope.courseVersionId,submission_id:submissionId,verification_run_id:verificationRunId,
        challenge_nonce:context.challenge_nonce,issued_at_epoch_seconds:context.issued_at_epoch_seconds,
        expires_at_epoch_seconds:context.expires_at_epoch_seconds,expected_revision:input.expectedRevision,
        expected_content_fingerprint:contentFingerprint,action_request_id:actionRequestId,
      };
      let signature:string;
      try{signature=signTrainingPublicationAuthorization(envelope,signing.privateKeyPem);}
      catch{throw new TrainingPublicationUnavailableError();}
      const rows=z.array(publicationRequestRow).length(1).parse(await rpc("request_internal_admin_training_publication",{
        ...base(scope),target_submission_id:envelope.submission_id,target_verification_run_id:envelope.verification_run_id,
        expected_revision:envelope.expected_revision,expected_content_fingerprint:envelope.expected_content_fingerprint,
        action_request_id:envelope.action_request_id,signed_authorization_envelope:envelope,authorization_signature:signature,
      }));
      return rows[0]!;
    },
    async retireCourse(scope,input){scopeSchema.parse(scope);return rpc("retire_internal_admin_training_course_version",{...base(scope),retirement_reason:input.reason,action_request_id:uuid.parse(input.requestId)});},
    async activateProgram(actorUserId,organizationId,programId,requestId){return rpc("activate_internal_admin_restaurant_training_program",{actor_user_id:uuid.parse(actorUserId),target_organization_id:uuid.parse(organizationId),target_program_id:uuid.parse(programId),action_request_id:uuid.parse(requestId)});},
    async retireProgram(actorUserId,organizationId,programId,reason,requestId){return rpc("retire_internal_admin_training_program",{actor_user_id:uuid.parse(actorUserId),target_organization_id:uuid.parse(organizationId),target_program_id:uuid.parse(programId),retirement_reason:reason,action_request_id:uuid.parse(requestId)});},
  };
}
