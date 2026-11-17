import {createClient} from "@supabase/supabase-js";
import {z} from "zod";

const auth={autoRefreshToken:false,detectSessionInUrl:false,persistSession:false} as const;
const uuid=z.uuid();

// ---------------------------------------------------------------------------
// Error hierarchy
// ---------------------------------------------------------------------------

type SafeUpstreamCode="PGRST202"|"42883"|"42P01"|"42703"|"42501"|"P0002"|"55000"|"22023";
const safeUpstreamCodes=new Set<SafeUpstreamCode>(["PGRST202","42883","42P01","42703","42501","P0002","55000","22023"]);
function safeUpstreamCode(value:unknown):SafeUpstreamCode|undefined{return typeof value==="string"&&safeUpstreamCodes.has(value as SafeUpstreamCode)?value as SafeUpstreamCode:undefined;}

export type TrainingSupervisorQuizPreviewFailureStage=
  |"rpc_call"
  |"response_parse"
  |"answer_key_leak";

export type TrainingSupervisorQuizPreviewSafeCategory=
  |"authorization"
  |"not_found"
  |"invalid_locale"
  |"contract_conflict"
  |"rpc_not_found"
  |"rpc_dependency"
  |"upstream_error"
  |"transport"
  |"invalid_result"
  |"schema_validation"
  |"answer_key_leak"
  |"unexpected_error";

export type TrainingSupervisorQuizPreviewDiagnostic={
  failureStage:TrainingSupervisorQuizPreviewFailureStage;
  safeCategory:TrainingSupervisorQuizPreviewSafeCategory;
  upstreamCode?:SafeUpstreamCode;
  issueCount?:number;
};

class TrainingSupervisorQuizPreviewError extends Error{
  constructor(readonly previewDiagnostic:TrainingSupervisorQuizPreviewDiagnostic){super();this.name="TrainingSupervisorQuizPreviewError";}
}
export class TrainingSupervisorQuizPreviewAccessError extends TrainingSupervisorQuizPreviewError{
  constructor(diagnostic:TrainingSupervisorQuizPreviewDiagnostic={failureStage:"rpc_call",safeCategory:"authorization"}){super(diagnostic);this.name="TrainingSupervisorQuizPreviewAccessError";}
}
export class TrainingSupervisorQuizPreviewNotFoundError extends TrainingSupervisorQuizPreviewError{
  constructor(diagnostic:TrainingSupervisorQuizPreviewDiagnostic={failureStage:"rpc_call",safeCategory:"not_found"}){super(diagnostic);this.name="TrainingSupervisorQuizPreviewNotFoundError";}
}
export class TrainingSupervisorQuizPreviewUnavailableError extends TrainingSupervisorQuizPreviewError{
  constructor(diagnostic:TrainingSupervisorQuizPreviewDiagnostic={failureStage:"rpc_call",safeCategory:"unexpected_error"}){super(diagnostic);this.name="TrainingSupervisorQuizPreviewUnavailableError";}
}
export class TrainingSupervisorQuizPreviewAnswerKeyLeakError extends TrainingSupervisorQuizPreviewError{
  constructor(){super({failureStage:"answer_key_leak",safeCategory:"answer_key_leak"});this.name="TrainingSupervisorQuizPreviewAnswerKeyLeakError";}
}

export function getTrainingSupervisorQuizPreviewDiagnostic(error:unknown):TrainingSupervisorQuizPreviewDiagnostic{
  if(error instanceof TrainingSupervisorQuizPreviewError)return error.previewDiagnostic;
  return{failureStage:"rpc_call",safeCategory:"unexpected_error"};
}

// ---------------------------------------------------------------------------
// Response types and validation schemas
// ---------------------------------------------------------------------------

/** A single answer option. Never contains correct_option_key or any correctness flag. */
export type TrainingSupervisorQuizOption={option_key:string;text:string};

/** A single question returned by the preview. Never contains answer keys. */
export type TrainingSupervisorQuizPreviewQuestion={
  question_number:number;
  question_key:string;
  prompt:string;
  options:TrainingSupervisorQuizOption[];
};

// .strict() on option ensures correct_option_key is rejected if ever present in a DB response.
const optionSchema=z.object({
  option_key:z.string().min(1),
  text:z.string().min(1),
}).strict();

const questionSchema=z.object({
  question_number:z.number().int().positive(),
  question_key:z.string().min(1),
  prompt:z.string().min(1),
  options:z.array(optionSchema).min(2).max(10),
}).strict();

// Exactly 27 questions required. Length is enforced at the service layer, not in the DB.
const responseSchema=z.array(questionSchema).length(27);

// ---------------------------------------------------------------------------
// Service interface
// ---------------------------------------------------------------------------

const VALID_LOCALES=["en","ar","id","hi","fil"] as const;
type SupportedLocale=typeof VALID_LOCALES[number];

export type TrainingSupervisorQuizPreviewService={
  getQuizPreview(
    actorUserId:string,
    credentialVersion:string,
    locale:SupportedLocale,
  ):Promise<TrainingSupervisorQuizPreviewQuestion[]>;
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export function createTrainingSupervisorQuizPreviewService(
  url:string,
  secretKey:string,
):TrainingSupervisorQuizPreviewService{
  const client=createClient(url,secretKey,{auth});

  async function callRpc(
    actorUserId:string,
    credentialVersion:string,
    locale:SupportedLocale,
  ):Promise<unknown[]>{
    // Validate UUIDs before hitting the DB.
    uuid.parse(actorUserId);
    uuid.parse(credentialVersion);

    let result;
    try{
      result=await client.rpc("get_training_supervisor_baladiyah_quiz_preview",{
        p_actor_user_id:actorUserId,
        p_expected_credential_version:credentialVersion,
        p_locale:locale,
      });
    }catch{
      throw new TrainingSupervisorQuizPreviewUnavailableError({failureStage:"rpc_call",safeCategory:"transport"});
    }

    if(result.error){
      const code=safeUpstreamCode(result.error.code);
      if(code==="42501")throw new TrainingSupervisorQuizPreviewAccessError({failureStage:"rpc_call",safeCategory:"authorization",upstreamCode:code});
      if(code==="P0002")throw new TrainingSupervisorQuizPreviewNotFoundError({failureStage:"rpc_call",safeCategory:"not_found",upstreamCode:code});
      if(code==="22023")throw new TrainingSupervisorQuizPreviewUnavailableError({failureStage:"rpc_call",safeCategory:"invalid_locale",upstreamCode:code});
      if(code==="55000")throw new TrainingSupervisorQuizPreviewUnavailableError({failureStage:"rpc_call",safeCategory:"contract_conflict",upstreamCode:code});
      if(code==="PGRST202")throw new TrainingSupervisorQuizPreviewUnavailableError({failureStage:"rpc_call",safeCategory:"rpc_not_found",upstreamCode:code});
      if(code==="42883"||code==="42P01"||code==="42703")throw new TrainingSupervisorQuizPreviewUnavailableError({failureStage:"rpc_call",safeCategory:"rpc_dependency",upstreamCode:code});
      throw new TrainingSupervisorQuizPreviewUnavailableError({failureStage:"rpc_call",safeCategory:"upstream_error"});
    }

    if(!Array.isArray(result.data)){
      throw new TrainingSupervisorQuizPreviewUnavailableError({failureStage:"response_parse",safeCategory:"invalid_result"});
    }
    return result.data;
  }

  return{
    async getQuizPreview(actorUserId,credentialVersion,locale){
      const raw=await callRpc(actorUserId,credentialVersion,locale);

      const parsed=responseSchema.safeParse(raw);
      if(!parsed.success){
        throw new TrainingSupervisorQuizPreviewUnavailableError({
          failureStage:"response_parse",
          safeCategory:"schema_validation",
          issueCount:parsed.error.issues.length,
        });
      }

      // Defense in depth: explicitly assert no answer keys leaked through .strict().
      // If correct_option_key is ever present, .strict() would have caught it above,
      // but we add a belt-and-suspenders string scan on the raw JSON.
      const rawJson=JSON.stringify(raw);
      if(/correct_option_key|answer_key|explanation/i.test(rawJson)){
        throw new TrainingSupervisorQuizPreviewAnswerKeyLeakError();
      }

      return parsed.data;
    },
  };
}
