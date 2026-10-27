import type { NextFunction, Request, Response } from "express";
import { HttpError } from "./errors";

export type MutationRateLimitRoute =
  | "opening_draft"
  | "opening_submit"
  | "oil_draft"
  | "oil_opening_submit"
  | "oil_closing_submit";

type Bucket = { count: number; expiresAt: number };

export type MutationRateLimiterOptions = {
  enabled: boolean;
  now?: () => number;
  maxEntries?: number;
  windowMs?: number;
  limits?: Partial<Record<MutationRateLimitRoute, number>>;
  onRejected?: (input: { route: MutationRateLimitRoute; retryAfterSeconds: number; requestId: string | null }) => void;
};

const DEFAULT_WINDOW_MS = 60_000;
const DEFAULT_MAX_ENTRIES = 4_096;
const DEFAULT_LIMITS: Record<MutationRateLimitRoute, number> = {
  opening_draft: 20,
  opening_submit: 6,
  oil_draft: 20,
  oil_opening_submit: 6,
  oil_closing_submit: 6,
};

function branchParam(request: Request) {
  const value = request.params.branchId;
  return typeof value === "string" && value.length <= 64 ? value : "invalid";
}

export function createMutationRateLimiter(options: MutationRateLimiterOptions) {
  const now = options.now ?? Date.now;
  const windowMs = options.windowMs ?? DEFAULT_WINDOW_MS;
  const maxEntries = Math.max(128, options.maxEntries ?? DEFAULT_MAX_ENTRIES);
  const limits = { ...DEFAULT_LIMITS, ...(options.limits ?? {}) };
  const buckets = new Map<string, Bucket>();

  function evict(current: number) {
    let examined = 0;
    for (const [key, bucket] of buckets) {
      if (bucket.expiresAt <= current) buckets.delete(key);
      examined += 1;
      if (examined >= 64) break;
    }
    while (buckets.size >= maxEntries) {
      const first = buckets.keys().next().value as string | undefined;
      if (!first) break;
      buckets.delete(first);
    }
  }

  function middleware(route: MutationRateLimitRoute) {
    return (request: Request, _response: Response, next: NextFunction) => {
      if (!options.enabled) {
        next();
        return;
      }
      const actor = request.auth?.userId;
      if (!actor) {
        next();
        return;
      }
      const current = now();
      evict(current);
      const key = `${route}:${actor}:${branchParam(request)}`;
      const existing = buckets.get(key);
      const bucket = existing && existing.expiresAt > current
        ? existing
        : { count: 0, expiresAt: current + windowMs };
      bucket.count += 1;
      buckets.set(key, bucket);
      const limit = limits[route];
      if (bucket.count > limit) {
        const retryAfterSeconds = Math.max(1, Math.ceil((bucket.expiresAt - current) / 1000));
        options.onRejected?.({ route, retryAfterSeconds, requestId: request.id ?? null });
        const error = new HttpError(429, "rate_limited", "Too many submissions. Try again shortly.");
        (error as HttpError & { retryAfterSeconds?: number }).retryAfterSeconds = retryAfterSeconds;
        next(error);
        return;
      }
      next();
    };
  }

  return { middleware, size: () => buckets.size, clear: () => buckets.clear() };
}
