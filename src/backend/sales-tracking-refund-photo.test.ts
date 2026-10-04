import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";
import { salesTrackingPhotoMime } from "./checklist-persistence";

const migrationPath=path.resolve("supabase/migrations/20261005120000_sales_tracking_refund_optional_photo.sql");

describe("Sales Tracking refund and optional photo contract",()=>{
  it("keeps gross, refund, net, and variance semantics explicit",async()=>{
    const source=await readFile(migrationPath,"utf8");
    assert.match(source,/add column refund_total numeric\(14,2\) not null default 0/);
    assert.match(source,/refund_total<=actual_cash\+actual_credit\+online_delivery/);
    assert.match(source,/'gross_sales',r\.actual_cash\+r\.actual_credit\+r\.online_delivery/);
    assert.match(source,/'net_sales',r\.actual_cash\+r\.actual_credit\+r\.online_delivery-r\.refund_total/);
    assert.match(source,/'variance',\(r\.actual_cash\+r\.actual_credit\+r\.online_delivery\)-\(r\.pos_cash\+r\.pos_credit\+r\.online_delivery\)/);
    assert.match(source,/coalesce\(row_value->>'refund_total',''\)/);
  });

  it("keeps evidence private, report-scoped, optional, and service-role only",async()=>{
    const source=await readFile(migrationPath,"utf8");
    assert.match(source,/values\('sales-tracking-evidence','sales-tracking-evidence',false,5242880/);
    assert.match(source,/foreign key\(report_id,organization_id,branch_id\)/);
    assert.match(source,/unique index sales_tracking_attachments_active_report_uidx/);
    assert.match(source,/where deleted_at is null/);
    assert.match(source,/revoke all on function public\.ensure_sales_tracking_draft_report/);
    assert.match(source,/to service_role/);
    assert.match(source,/if s\.state<>'draft'/);
  });

  it("recognizes JPEG, PNG, and WebP by signature and rejects mismatches",()=>{
    assert.deepEqual(salesTrackingPhotoMime(Buffer.from([0xff,0xd8,0xff,0xdb]),"image/jpeg"),{mimeType:"image/jpeg",extension:"jpg"});
    assert.deepEqual(salesTrackingPhotoMime(Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]),"image/png"),{mimeType:"image/png",extension:"png"});
    assert.deepEqual(salesTrackingPhotoMime(Buffer.from("RIFF0000WEBP","ascii"),"image/webp"),{mimeType:"image/webp",extension:"webp"});
    assert.throws(()=>salesTrackingPhotoMime(Buffer.from([0xff,0xd8,0xff]),"image/png"));
    assert.throws(()=>salesTrackingPhotoMime(Buffer.from("not-an-image"),"image/jpeg"));
  });
});
