import { z } from "zod";

export const SALES_TRACKING_PERIOD_CURSOR_VERSION = 1 as const;

const cursorSchema = z.object({
  v: z.literal(SALES_TRACKING_PERIOD_CURSOR_VERSION),
  organization_id: z.uuid(),
  branch_id: z.uuid().nullable(),
  date_from: z.iso.date(),
  date_to: z.iso.date(),
  authority_revision: z.string().regex(/^[0-9a-f]{32}$/u),
  business_date: z.iso.date(),
  item_branch_id: z.uuid(),
  report_id: z.uuid(),
  display_order: z.number().int().min(1).max(3),
  attachment_id: z.uuid(),
}).strict();

export type SalesTrackingPeriodCursor = z.infer<typeof cursorSchema>;
export type SalesTrackingPeriodCursorScope = Pick<SalesTrackingPeriodCursor,
  "organization_id" | "branch_id" | "date_from" | "date_to"
>;

export function encodeSalesTrackingPeriodCursor(cursor: SalesTrackingPeriodCursor) {
  return Buffer.from(JSON.stringify(cursorSchema.parse(cursor)), "utf8").toString("base64url");
}

export function decodeSalesTrackingPeriodCursor(value: string, scope: SalesTrackingPeriodCursorScope) {
  if (!value || value.length > 1024 || !/^[A-Za-z0-9_-]+$/u.test(value)) return null;
  try {
    const decoded = Buffer.from(value, "base64url").toString("utf8");
    if (Buffer.from(decoded, "utf8").toString("base64url") !== value) return null;
    const cursor = cursorSchema.parse(JSON.parse(decoded));
    if (
      cursor.organization_id !== scope.organization_id ||
      cursor.branch_id !== scope.branch_id ||
      cursor.date_from !== scope.date_from ||
      cursor.date_to !== scope.date_to
    ) return null;
    return cursor;
  } catch {
    return null;
  }
}
