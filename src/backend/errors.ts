import type {
  ErrorRequestHandler,
  NextFunction,
  Request,
  Response,
} from "express";

type ErrorCode =
  | "bad_request"
  | "conflict"
  | "duplicate_branch_code"
  | "duplicate_employee_code"
  | "duplicate_person_code"
  | "forbidden"
  | "invalid_country"
  | "invalid_iqama_expiry"
  | "invalid_profile"
  | "invalid_json"
  | "not_found"
  | "payload_too_large"
  | "rate_limited"
  | "service_unavailable"
  | "unauthorized"
  | "unprocessable_entity";

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: ErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "HttpError";
  }
}

export function notFoundHandler(
  _request: Request,
  _response: Response,
  next: NextFunction,
) {
  next(new HttpError(404, "not_found", "The requested resource was not found."));
}

function isBodyParserError(
  error: unknown,
): error is { status: number; type?: string } {
  return (
    typeof error === "object" &&
    error !== null &&
    "status" in error &&
    typeof error.status === "number"
  );
}

export const errorHandler: ErrorRequestHandler = (
  error,
  request,
  response,
  next,
) => {
  void next;
  let normalized =
    error instanceof HttpError
      ? error
      : new HttpError(500, "service_unavailable", "The service is unavailable.");

  if (
    !(error instanceof HttpError) &&
    isBodyParserError(error) &&
    error.status === 400
  ) {
    normalized = new HttpError(400, "invalid_json", "The JSON body is invalid.");
  } else if (
    !(error instanceof HttpError) &&
    isBodyParserError(error) &&
    error.status === 413
  ) {
    normalized = new HttpError(
      413,
      "payload_too_large",
      "The request body is too large.",
    );
  }

  if (
    normalized.status >= 500 &&
    request.app.get("env") !== "test" &&
    !request.safeFailureLogged
  ) {
    console.error("API request failed", {
      requestId: request.id,
      method: request.method,
      path: request.path,
      errorType: error instanceof Error ? error.name : "UnknownError",
    });
  }

  response.status(normalized.status).json({
    error: {
      code: normalized.code,
      message: normalized.message,
      requestId: request.id,
    },
  });
};
