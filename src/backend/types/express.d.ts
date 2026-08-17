import type { UserContextRepository } from "../user-context";

declare global {
  namespace Express {
    interface Request {
      id: string;
      safeFailureLogged?: boolean;
      auth?: {
        userId: string;
        email: string;
        userContext: UserContextRepository;
      };
    }
  }
}

export {};
