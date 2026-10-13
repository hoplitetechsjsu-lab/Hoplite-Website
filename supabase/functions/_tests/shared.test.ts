// _shared/cors.ts + _shared/supabase.ts (callerContext / publicContext / hashToken).
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { corsHeaders, json } from '../_shared/cors.ts';
import { callerContext, hashToken, publicContext } from '../_shared/supabase.ts';
import { contextCalls } from './mocks/supabase-server.ts';
import { makeWorld, readJson, req, sha256 } from './helpers.ts';

Deno.test('json(): status, content-type and CORS headers', async () => {
  const res = json({ a: 1 }, 418);
  assertEquals(res.status, 418);
  assertEquals(res.headers.get('Content-Type'), 'application/json');
  assertEquals(res.headers.get('Access-Control-Allow-Origin'), '*');
  assertEquals(await res.json(), { a: 1 });
});

Deno.test('corsHeaders allow the headers the browser client sends', () => {
  const allowed = corsHeaders['Access-Control-Allow-Headers'].split(',').map((h) => h.trim());
  for (const h of ['authorization', 'x-client-info', 'apikey', 'content-type']) assert(allowed.includes(h), h);
  assert(corsHeaders['Access-Control-Allow-Methods'].includes('OPTIONS'));
  assert(corsHeaders['Access-Control-Allow-Methods'].includes('POST'));
});

Deno.test('callerContext: OPTIONS short-circuits with CORS and never builds a context', async () => {
  makeWorld();
  contextCalls.length = 0;
  const { ctx, response } = await callerContext(req(null, { method: 'OPTIONS' }));
  assertEquals(ctx, null);
  assertEquals(response?.status, 200);
  assertEquals(response?.headers.get('Access-Control-Allow-Origin'), '*');
  assertEquals(contextCalls.length, 0);
});

Deno.test('publicContext: OPTIONS short-circuits with CORS', async () => {
  makeWorld();
  contextCalls.length = 0;
  const { ctx, response } = await publicContext(req(null, { method: 'OPTIONS' }));
  assertEquals(ctx, null);
  assertEquals(response?.status, 200);
  assertEquals(contextCalls.length, 0);
});

Deno.test('callerContext: missing / invalid / expired JWT -> SDK 401 as JSON with CORS', async () => {
  makeWorld();
  for (const token of [null, 'junk', 'expired', 'valid:unknown-id']) {
    const { ctx, response } = await callerContext(req({}, { token }));
    assertEquals(ctx, null, String(token));
    assertEquals(response?.status, 401, String(token));
    assertEquals(response?.headers.get('Access-Control-Allow-Origin'), '*');
    assert((await readJson(response!)).error);
  }
});

Deno.test('callerContext: valid JWT -> ctx with caller + admin clients; requests auth "user"', async () => {
  const w = makeWorld();
  const a = w.authUser('alice');
  contextCalls.length = 0;
  const { ctx, response } = await callerContext(req({}, { token: a.token }));
  assertEquals(response, null);
  assert(ctx?.supabase && ctx.supabaseAdmin);
  assertEquals(ctx?.userClaims.id, a.authId);
  assertEquals(contextCalls, [{ auth: 'user', hasAuthHeader: true }]);
});

Deno.test('publicContext: no JWT needed; requests auth "none"', async () => {
  makeWorld();
  contextCalls.length = 0;
  const { ctx, response } = await publicContext(req({}));
  assertEquals(response, null);
  assert(ctx?.supabaseAdmin);
  assertEquals(contextCalls, [{ auth: 'none', hasAuthHeader: false }]);
});

Deno.test('hashToken: SHA-256 hex, deterministic, matches independent digest', async () => {
  const h = await hashToken('abc');
  assertEquals(h, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  assertEquals(h, await hashToken('abc'));
  assertEquals(h, await sha256('abc'));
  assert(/^[0-9a-f]{64}$/.test(await hashToken('')));
  assert((await hashToken('a')) !== (await hashToken('b')));
});
