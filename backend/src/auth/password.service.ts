import { Injectable } from '@nestjs/common';
import { hash as argonHash, verify as argonVerify, type Algorithm } from '@node-rs/argon2';

/**
 * `Algorithm.Argon2id`, inlined as its numeric value.
 *
 * @node-rs/argon2 declares `Algorithm` as an *ambient* const enum, and
 * `isolatedModules` forbids reading its members because the transpiler cannot
 * inline them (TS2748). swc does not typecheck, so this compiles and the
 * tests pass — only `tsc --noEmit` catches it. Run the typecheck.
 *
 * argon2id also happens to be the library default, but stating it explicitly
 * means an upstream default change cannot silently downgrade us.
 */
const ARGON2ID = 2 as Algorithm;

@Injectable()
export class PasswordService {
  // OWASP-recommended argon2id baseline. Raising these later is safe: every
  // hash encodes the parameters it was created with, so existing passwords
  // keep verifying against the old cost while new ones use the new cost.
  private static readonly OPTIONS = {
    algorithm: ARGON2ID,
    memoryCost: 19456, // 19 MiB
    timeCost: 2,
    parallelism: 1,
  } as const;

  /**
   * A real argon2id hash of a random string that nobody knows.
   *
   * The login path verifies against this when the username does not exist, so
   * a missing account costs the same time as a wrong password. Without it,
   * "no such user" returns in microseconds while "wrong password" takes ~50ms,
   * and that gap alone lets anyone enumerate which clinics have accounts.
   *
   * It must be a *valid* hash — a placeholder string would make verify() bail
   * early and reintroduce the very timing difference this exists to close.
   */
  static readonly DUMMY_HASH =
    '$argon2id$v=19$m=19456,t=2,p=1$Ne9KI+UAtEqPPUGQt/j5cQ$bw37w2PvTh2PhkqBxdmkS6ZpBqM5qZazLVQjggiMQmU';

  hash(plain: string): Promise<string> {
    return argonHash(plain, PasswordService.OPTIONS);
  }

  async verify(hash: string, plain: string): Promise<boolean> {
    try {
      return await argonVerify(hash, plain, PasswordService.OPTIONS);
    } catch {
      // A malformed or truncated hash is a failed login, not a 500. Throwing
      // here would turn one corrupt row into an outage.
      return false;
    }
  }
}
