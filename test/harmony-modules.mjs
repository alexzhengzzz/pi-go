import { existsSync, readFileSync } from 'node:fs';
import { registerHooks, stripTypeScriptTypes } from 'node:module';

const root = new URL('../harmony/entry/src/main/ets/', import.meta.url).href;

// ArkTS logic modules are TypeScript. Resolve their extensionless imports as
// ArkTS does, and substitute only the system APIs used by these tests.
const systemMocks = new Map([
  ['@kit.ArkTS', `export const util = {
    TextEncoder, Base64Helper: class {},
    TextDecoder: class {
      constructor(encoding) { this.decoder = new TextDecoder(encoding); }
      decodeWithStream(bytes, options) { return this.decoder.decode(bytes, options); }
      static create(encoding, options) {
        const decoder = new TextDecoder(encoding, options);
        return { decodeToString: (bytes, decodeOptions) => decoder.decode(bytes, decodeOptions) };
      }
    }
  };`],
  ['@kit.NetworkKit', `export const http = {
    RequestMethod: { GET: 'GET', POST: 'POST' },
    HttpDataType: { STRING: 'string' },
    createHttp: () => globalThis.pigoTestHttp.createHttp()
  }; export const socket = {};`],
  ['@kit.CoreFileKit', `export const fileIo = new Proxy({}, {
    get(_target, key) {
      const api = globalThis.pigoTestFiles;
      const member = api[key];
      return typeof member === 'function' ? member.bind(api) : member;
    }
  });`],
  ['@kit.ArkData', 'export const preferences = {};'],
  ['@kit.CryptoArchitectureKit', 'export const cryptoFramework = {};'],
  ['@kit.UniversalKeystoreKit', 'export const huks = {};'],
]);

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (context.parentURL?.startsWith(root)) {
      if (systemMocks.has(specifier)) {
        return { url: 'data:text/javascript,' + encodeURIComponent(systemMocks.get(specifier)), shortCircuit: true };
      }
      if (specifier.startsWith('.') && !specifier.endsWith('.ets')) {
        const candidate = new URL(specifier + '.ets', context.parentURL);
        if (existsSync(candidate)) return { url: candidate.href, shortCircuit: true };
      }
    }
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url.startsWith(root) && url.endsWith('.ets')) {
      const source = readFileSync(new URL(url), 'utf8');
      return { format: 'module', source: stripTypeScriptTypes(source), shortCircuit: true };
    }
    return nextLoad(url, context);
  },
});
