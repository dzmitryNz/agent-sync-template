#!/usr/bin/env node
/**
 * Canonical local-stand service starter (agent-devops).
 *
 * Loads .env then .env.local then any extra env files into process.env
 * (last assignment wins), then spawns `npx tsx src/app.ts` detached.
 * Do NOT use npm run dev / tsx watch / vite — those skip .env.local injection
 * and trip ENOSPC on shared hosts.
 *
 * Usage:
 *   node ~/.claude/skills/agent-devops/start-svc.mjs <dir> <logPath> <pidPath> [extra.env ...]
 *
 * Prints one JSON line: { pid, dir, PORT, <keys from STAND_REPORT_ENV> }|DB_HOST, DB_PORT, DB_NAME, hasApiToken }
 */
import { spawn } from 'node:child_process';
import { existsSync, openSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const dir = process.argv[2];
const logPath = process.argv[3];
const pidPath = process.argv[4];
const extraFiles = process.argv.slice(5);

if (!dir || !logPath || !pidPath) {
  console.error(
    'Usage: start-svc.mjs <dir> <logPath> <pidPath> [extra.env ...]',
  );
  process.exit(2);
}

function parseEnv(path) {
  if (!existsSync(path)) return {};
  const out = {};
  for (const raw of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const i = line.indexOf('=');
    if (i <= 0) continue;
    let key = line.slice(0, i).trim();
    let val = line.slice(i + 1);
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    out[key] = val;
  }
  return out;
}

const env = { ...process.env };
Object.assign(env, parseEnv(resolve(dir, '.env')));
Object.assign(env, parseEnv(resolve(dir, '.env.local')));
for (const f of extraFiles) Object.assign(env, parseEnv(f));

const log = openSync(logPath, 'w');
const child = spawn('npx', ['tsx', 'src/app.ts'], {
  cwd: dir,
  env,
  detached: true,
  stdio: ['ignore', log, log],
});
child.unref();
writeFileSync(pidPath, String(child.pid) + '\n');

// Report selected env keys (STAND_REPORT_ENV, comma-separated; default DB_HOST,DB_PORT,DB_NAME).
const report = {};
for (const k of (process.env.STAND_REPORT_ENV || 'DB_HOST,DB_PORT,DB_NAME').split(',')) {
  if (k) report[k] = env[k] || null;
}
console.log(JSON.stringify({ pid: child.pid, dir, PORT: env.PORT, ...report }));
