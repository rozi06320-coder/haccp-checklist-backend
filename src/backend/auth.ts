import type { NextFunction, Request, Response } from "express";
import { HttpError } from "./errors";
import type {
  AuthVerifier,
  UserContextRepositoryFactory,
} from "./dependencies";

const MAX_BEARER_TOKEN_LENGTH = 8_192;
const bearerTokenPattern = /^Bearer ([^\s]+)$/;

export function requireAuthentication(
  authVerifier: AuthVerifier,
  createUserContext: UserContextRepositoryFactory,
) {
  return async function authenticate(
    request: Request,
    _response: Response,
    next: NextFunction,
  ) {
    const authorization = request.header("authorization");
    const match =
      authorization && authorization.length <= MAX_BEARER_TOKEN_LENGTH + 7
        ? authorization.match(bearerTokenPattern)
        : null;

    if (!match || match[1].length > MAX_BEARER_TOKEN_LENGTH) {
      next(new HttpError(401, "unauthorized", "Authentication is required."));
      return;
    }

    try {
      const identity = await authVerifier.verify(match[1]);

      if (!identity) {
        next(new HttpError(401, "unauthorized", "Authentication is required."));
        return;
      }

      request.auth = {
        userId: identity.userId,
        email: identity.email,
        userContext: createUserContext(match[1]),
      };
      next();
    } catch {
      next(new HttpError(401, "unauthorized", "Authentication is required."));
    }
  };
}

export { MAX_BEARER_TOKEN_LENGTH };
