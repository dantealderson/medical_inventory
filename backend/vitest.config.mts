import swc from 'unplugin-swc';
import { defineConfig } from 'vitest/config';

// Unit tests only — no database required, so this suite always runs.
//
// Vitest rather than jest because NestJS 12 is ESM-only ("type": "module",
// no require export condition). Jest's runtime cannot require() an ESM
// package, and its ESM mode needs --experimental-vm-modules plus migrating
// the whole backend to ESM. Vitest handles it natively.
//
// The .mts extension keeps Vite's native config loader happy about ESM syntax.
export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['test/unit/**/*.spec.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      exclude: ['src/**/*.module.ts', 'src/main.ts'],
    },
  },
  // swc handles emitDecoratorMetadata, which Nest's constructor injection
  // depends on. Verified: @Injectable constructor params resolve correctly.
  plugins: [swc.vite({ module: { type: 'es6' } })],
});
