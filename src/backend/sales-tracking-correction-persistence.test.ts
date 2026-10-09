import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";
import path from "node:path";
import {
  ChecklistConflictError,
  runSalesTrackingCorrectionSaveRpc,
  salesTrackingCorrectionRpcArgs,
  salesTrackingCorrectionSaveDiagnosticCategory,
  salesTrackingCorrectionSaveDiagnosticReason,
  type SalesTrackingCorrectionSaveDiagnosticEvent,
  type SalesTrackingDraftPayload,
} from "./checklist-persistence";

const actorUserId="11000000-0000-4000-8000-000000000001";
const branchId="22000000-0000-4000-8000-000000000001";
const reportId="33000000-0000-4000-8000-000000000001";
const requestId="44000000-0000-4000-8000-000000000001";

const payload:SalesTrackingDraftPayload={
  sales_rows:[{
    entry_date:"2026-10-07",
    actual_cash:"10.25",
    actual_credit:"20.50",
    pos_cash:"9.25",
    pos_credit:"21.50",
    online_delivery:"7.75",
    refund_total:"1.25",
    online_amounts:[
      {provider_id:"55000000-0000-4000-8000-000000000001",amount:"5.25"},
      {provider_id:"55000000-0000-4000-8000-000000000002",amount:"2.50"},
    ],
    remarks:"corrected sales",
  }],
  cash_rows:[{
    entry_date:"2026-10-07",
    denominations:{"1":1,"2":2,"5":3,"10":4,"20":5,"50":6,"100":7,"200":8,"500":9},
    remaining_cash:"12.50",
    remarks:"corrected cash",
  }],
};

describe("Sales Tracking correction persistence boundary",()=>{
  it("uses the bounded correction failure categories",()=>{
    assert.equal(salesTrackingCorrectionSaveDiagnosticCategory("PT409"),"stale_revision");
    assert.equal(salesTrackingCorrectionSaveDiagnosticCategory("23514"),"validation_check");
    assert.equal(salesTrackingCorrectionSaveDiagnosticCategory("55000"),"lifecycle_conflict");
    assert.equal(salesTrackingCorrectionSaveDiagnosticCategory("23505"),"unique_conflict");
    assert.equal(salesTrackingCorrectionSaveDiagnosticCategory("42501"),"authorization");
    assert.equal(salesTrackingCorrectionSaveDiagnosticCategory("unexpected"),"unknown");
  });

  it("maps only exact allowlisted 23514 messages to safe reasons",()=>{
    assert.equal(salesTrackingCorrectionSaveDiagnosticReason("23514","sales tracking online provider total mismatch"),"online_provider_total_mismatch");
    assert.equal(salesTrackingCorrectionSaveDiagnosticReason("23514",'new row for relation "sales_tracking_sales_rows" violates check constraint "sales_tracking_sales_rows_refund_not_over_gross_check"'),"refund_validation");
    assert.equal(salesTrackingCorrectionSaveDiagnosticReason("23514",'new row for relation "sales_tracking_cash_rows" violates check constraint "sales_tracking_cash_rows_remaining_cash_check"'),"cash_validation");
    assert.equal(salesTrackingCorrectionSaveDiagnosticReason("23514","invalid sales tracking online amount row"),"online_amount_row_validation");
    assert.equal(salesTrackingCorrectionSaveDiagnosticReason("23514","unrecognized raw database message"),"validation_check_unknown");
    assert.equal(salesTrackingCorrectionSaveDiagnosticReason("PT409","sales tracking online provider total mismatch"),null);
  });

  it("wires correction saves through the shared normalizer and diagnostic runner",async()=>{
    const source=await readFile(path.resolve("src/backend/checklist-persistence.ts"),"utf8");
    const method=source.slice(source.indexOf("async saveSalesTrackingCorrection(input)"),source.indexOf("async submitSalesTrackingCorrection(input)"));
    assert.match(method,/salesTrackingCorrectionRpcArgs\(/);
    assert.match(method,/runSalesTrackingCorrectionSaveRpc\(/);
    assert.doesNotMatch(method,/sales_rows:input\.payload\.sales_rows|cash_rows:input\.payload\.cash_rows/);
  });

  it("preserves the expected revision and normalizes the correction RPC payload",()=>{
    const args=salesTrackingCorrectionRpcArgs(actorUserId,branchId,reportId,7,"closing_shift",payload);

    assert.equal(args.expected_revision,7);
    assert.deepEqual(args.sales_rows,payload.sales_rows);
    assert.deepEqual(args.cash_rows,[{
      entry_date:"2026-10-07",
      denom_1:1,denom_2:2,denom_5:3,denom_10:4,denom_20:5,denom_50:6,denom_100:7,denom_200:8,denom_500:9,
      remaining_cash:"12.50",
      remarks:"corrected cash",
    }]);
    assert.equal("denominations" in args.cash_rows[0],false);
    assert.equal(args.sales_rows[0].refund_total,"1.25");
    assert.deepEqual(args.sales_rows[0].online_amounts,payload.sales_rows[0].online_amounts);
  });

  for(const [sqlstate,category] of [["23514","validation_check"],["PT409","stale_revision"],["55000","lifecycle_conflict"]] as const){
    it(`classifies ${sqlstate} as ${category}`,async()=>{
      const events:SalesTrackingCorrectionSaveDiagnosticEvent[]=[];
      await assert.rejects(
        runSalesTrackingCorrectionSaveRpc(async()=>({data:null,error:{code:sqlstate,message:"raw database message"}}),7,{requestId,log:(event)=>events.push(event)}),
        (error:unknown)=>error instanceof ChecklistConflictError&&error.sqlstate===sqlstate,
      );
      assert.deepEqual(events,[{requestId,action:"save_sales_tracking_correction",expectedRevision:7,sqlstate,category,reason:sqlstate==="23514"?"validation_check_unknown":null}]);
    });
  }

  it("logs the allowlisted reason for a known provider mismatch",async()=>{
    const events:SalesTrackingCorrectionSaveDiagnosticEvent[]=[];
    await assert.rejects(
      runSalesTrackingCorrectionSaveRpc(async()=>({data:null,error:{code:"23514",message:"sales tracking online provider total mismatch"}}),7,{requestId,log:(event)=>events.push(event)}),
      ChecklistConflictError,
    );
    assert.deepEqual(events,[{requestId,action:"save_sales_tracking_correction",expectedRevision:7,sqlstate:"23514",category:"validation_check",reason:"online_provider_total_mismatch"}]);
  });

  it("logs a bounded diagnostic without payloads, identities, raw messages, or stack traces",async()=>{
    const records:unknown[][]=[],originalInfo=console.info;
    console.info=(...args:unknown[])=>{records.push(args);};
    try{
      await assert.rejects(runSalesTrackingCorrectionSaveRpc(async()=>({data:null,error:{code:"23514",message:"amount=999 provider=secret-provider user=secret-user report=secret-report"}}),7,{requestId}),ChecklistConflictError);
    }finally{console.info=originalInfo;}

    assert.equal(records.length,1);
    const serialized=JSON.stringify(records);
    assert.match(serialized,/SALES_TRACKING_CORRECTION_SAVE/);
    assert.match(serialized,/validation_check/);
    assert.doesNotMatch(serialized,/999|secret-provider|secret-user|secret-report|raw database|stack/i);
    assert.match(serialized,/validation_check_unknown/);
    assert.deepEqual(Object.keys(JSON.parse(String(records[0][0]).replace(/^SALES_TRACKING_CORRECTION_SAVE /u,""))).sort(),["action","category","expectedRevision","reason","requestId","sqlstate"]);
  });
});
