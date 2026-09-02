import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { describe, it } from "node:test";
import {
  canonicalizeMaintenancePurchasePayload,
  createOperationalAdmin,
  maintenancePurchaseRequestHash,
  OperationalInputError,
  type CanonicalMaintenancePurchasePayload,
} from "./operational";

const actorUserId="31000000-0000-4000-8000-000000000001";
const organizationId="11000000-0000-4000-8000-000000000001";
const branchId="21000000-0000-4000-8000-000000000001";
const purchaseId="71000000-0000-4000-8000-000000000001";
const idempotencyKey="81000000-0000-4000-8000-000000000001";

const generalItem={
  category:"general_supplies" as const,
  item_name:"Cleaning supplies",
  quantity:1,
  unit:"box" as const,
  amount:25,
  vendor_name:"Supply Shop",
  purchase_date:"2026-09-03",
  notes:null,
  payment_method:"credit_card" as const,
};

function hash(payload:CanonicalMaintenancePurchasePayload,bytes=Buffer.from("same evidence")){
  return maintenancePurchaseRequestHash({issueId:null,payload,receipts:[{bytes,mimeType:"application/pdf"}]});
}

describe("Maintenance Vendor/Service Phase B canonical writer contract",()=>{
  it("keeps historical other purchases and canonicalizes omitted and explicit other identically",()=>{
    const omitted=canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,destination:"  CEO   House  "}});
    const explicit=canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,purchase_type:"general",purchase_scope:"other",branch_id:null,destination:"CEO House"}});
    const nullable=canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,purchase_scope:null,destination:"CEO House"}});
    assert.deepEqual(omitted,explicit);
    assert.deepEqual(nullable,explicit);
    assert.deepEqual(omitted,{
      purchase_type:"general",purchase_scope:"other",branch_id:null,destination:"CEO House",
      category:"general_supplies",item_name:"Cleaning supplies",quantity:1,unit:"box",amount:25,
      vendor_name:"Supply Shop",purchase_date:"2026-09-03",notes:null,payment_method:"credit_card",
    });
    assert.equal(hash(omitted),hash(explicit));
  });

  it("canonicalizes branch and office authority fields and rejects invalid scope combinations",()=>{
    const branch=canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,purchase_scope:"branch",branch_id:branchId,destination:"Browser-supplied branch name"}});
    const branchOmittedDestination=canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,purchase_scope:"branch",branch_id:branchId}});
    assert.deepEqual(branch,branchOmittedDestination);
    assert.equal(hash(branch),hash(branchOmittedDestination));
    assert.equal(branch.branch_id,branchId);
    assert.equal(branch.destination,null);
    const officeOmitted=canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,purchase_scope:"office"}});
    const officeExplicit=canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,purchase_scope:"office",destination:"Office"}});
    assert.deepEqual(officeOmitted,officeExplicit);
    assert.equal(officeOmitted.branch_id,null);
    assert.equal(officeOmitted.destination,"Office");
    assert.equal(hash(officeOmitted),hash(officeExplicit));
    assert.throws(()=>canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,purchase_scope:"branch"}}),OperationalInputError);
    assert.throws(()=>canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,purchase_scope:"office",branch_id:branchId}}),OperationalInputError);
    assert.throws(()=>canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,purchase_scope:"other",branch_id:branchId,destination:"Warehouse"}}),OperationalInputError);
    assert.throws(()=>canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,purchase_scope:"other",destination:"   "}}),OperationalInputError);
  });

  it("accepts only the canonical service pair with quantity one and a real provider",()=>{
    const service=canonicalizeMaintenancePurchasePayload({issueId:null,payload:{
      purchase_type:"general",purchase_scope:"branch",branch_id:branchId,category:"service",unit:"service",
      item_name:"Monthly deep cleaning",quantity:"1",amount:"350",vendor_name:"  Dr.   Clean  ",
      purchase_date:"2026-09-02",payment_method:"cash",
    }});
    assert.deepEqual(service,{
      purchase_type:"general",purchase_scope:"branch",branch_id:branchId,destination:null,
      category:"service",item_name:"Monthly deep cleaning",quantity:1,unit:"service",amount:350,
      vendor_name:"Dr. Clean",purchase_date:"2026-09-02",notes:null,payment_method:"cash",
    });
    assert.throws(()=>canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,category:"service"}}),OperationalInputError);
    assert.throws(()=>canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...generalItem,unit:"service"}}),OperationalInputError);
    assert.throws(()=>canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...service,quantity:2}}),OperationalInputError);
    for(const vendor_name of [undefined,null,"","  n/A  "]){
      assert.throws(()=>canonicalizeMaintenancePurchasePayload({issueId:null,payload:{...service,vendor_name}}),OperationalInputError);
    }
    assert.throws(()=>canonicalizeMaintenancePurchasePayload({issueId:"41000000-0000-4000-8000-000000000001",payload:service}),OperationalInputError);
    const issuePayload={...generalItem,category:"spare_parts" as const,unit:"pcs" as const};
    assert.equal(canonicalizeMaintenancePurchasePayload({issueId:"41000000-0000-4000-8000-000000000001",payload:issuePayload}),issuePayload);
  });

  it("hashes the exact canonical payload sent to the RPC and preserves replay diagnostics",async()=>{
    const requests:Array<Record<string,unknown>>=[];
    let savedPurchaseId:string|null=null;
    const rpc=createServer(async(request,response)=>{
      let raw="";for await(const chunk of request)raw+=chunk;
      const body=JSON.parse(raw)as{payload:Record<string,unknown>};
      requests.push(body);
      savedPurchaseId??=String(body.payload.purchase_id);
      response.setHeader("content-type","application/json");
      response.end(JSON.stringify([{
        id:savedPurchaseId,organization_id:organizationId,branch_id:body.payload.branch_id,maintenance_issue_id:null,maintenance_user_id:actorUserId,
        purchase_type:body.payload.purchase_type,purchase_scope:body.payload.purchase_scope,destination:body.payload.destination,
        category:body.payload.category,item_name:body.payload.item_name,quantity:body.payload.quantity,unit:body.payload.unit,
        amount:body.payload.amount,vendor_name:body.payload.vendor_name,purchase_date:body.payload.purchase_date,notes:body.payload.notes,
        payment_status:"unpaid",payment_method:body.payload.payment_method,reimbursement_note:null,reimbursed_at:null,reimbursed_by:null,
        receipt_storage_path:null,receipt_original_name:null,attachments:[],created_at:"2026-09-03T10:00:00Z",updated_at:"2026-09-03T10:00:00Z",
      }]));
    });
    await new Promise<void>((resolve)=>rpc.listen(0,"127.0.0.1",resolve));
    try{
      const admin=createOperationalAdmin(`http://127.0.0.1:${(rpc.address()as AddressInfo).port}`,"service-key");
      const canonical=canonicalizeMaintenancePurchasePayload({issueId:null,payload:{
        purchase_scope:"office",destination:"browser value",category:"service",unit:"service",item_name:"Monthly deep cleaning",
        quantity:1,amount:350,vendor_name:"Dr. Clean",purchase_date:"2026-09-02",payment_method:"cash",
      }});
      const diagnostics:Array<{stage:string;outcome:string}>=[];
      const create=()=>admin.createMaintenancePurchase({actorUserId,idempotencyKey,payload:canonical,diagnostics:{log:event=>diagnostics.push({stage:event.stage,outcome:event.outcome})}})as Promise<{created:boolean}>;
      const first=await create(),replay=await create();
      assert.equal(first.created,true);
      assert.equal(replay.created,false);
      assert.equal(requests.length,2);
      const sentPayloads=requests.map(request=>request.payload as Record<string,unknown>);
      const expectedHash=maintenancePurchaseRequestHash({issueId:null,payload:canonical,receipts:[]});
      assert.equal(sentPayloads[0]?.request_hash,expectedHash);
      assert.equal(sentPayloads[1]?.request_hash,expectedHash);
      for(const sent of sentPayloads){
        const{purchase_id,idempotency_key,request_hash,receipt_storage_path,receipt_original_name,attachments,...businessPayload}=sent;
        assert.deepEqual(businessPayload,canonical);
        assert.equal(idempotency_key,idempotencyKey);
        assert.equal(typeof purchase_id,"string");
        assert.equal(request_hash,expectedHash);
        assert.equal(receipt_storage_path,null);
        assert.equal(receipt_original_name,null);
        assert.deepEqual(attachments,[]);
      }
      assert.deepEqual(diagnostics.map(({stage,outcome})=>({stage,outcome})),[
        {stage:"evidence_validation",outcome:"start"},{stage:"evidence_validation",outcome:"success"},
        {stage:"storage_upload",outcome:"start"},{stage:"storage_upload",outcome:"success"},
        {stage:"purchase_rpc",outcome:"start"},{stage:"purchase_rpc",outcome:"success"},
        {stage:"response_parse",outcome:"start"},{stage:"response_parse",outcome:"success"},
        {stage:"evidence_validation",outcome:"start"},{stage:"evidence_validation",outcome:"success"},
        {stage:"storage_upload",outcome:"start"},{stage:"storage_upload",outcome:"success"},
        {stage:"purchase_rpc",outcome:"start"},{stage:"purchase_rpc",outcome:"success"},
        {stage:"response_parse",outcome:"start"},{stage:"response_parse",outcome:"success"},
      ]);
      assert.notEqual(hash(canonical),hash({...canonical,amount:351}));
      assert.notEqual(hash(canonical),hash(canonical,Buffer.from("changed evidence")));
    }finally{
      await new Promise<void>((resolve,reject)=>rpc.close(error=>error?reject(error):resolve()));
    }
  });
});
