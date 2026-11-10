#!/usr/bin/env node
'use strict';
/*
 * toneperfect-lint — check reference texts before anyone records them.
 *
 *   npx toneperfect-lint "我有三本书" --language zh-CN
 *   npx toneperfect-lint --file lesson.txt --language fr-FR      (one text per line)
 *   npx toneperfect-lint --file lesson.csv                       (text,language[,pinyin] per line)
 *   npx toneperfect-lint --file lesson.jsonl                     ({"text","language","pinyin"} per line)
 *
 * Calls POST /v1/lint (free, no API key; texts are checked, not stored).
 * Exit 0 = no errors, 1 = at least one text has an error, 2 = usage/network.
 * --json prints one JSON result per text; --base-url overrides the API origin.
 */
const { readFileSync } = require('node:fs');
const { TonePerfect } = require('../index.cjs');

function parseArgs(argv) {
  const out = { texts: [], language: 'zh-CN', pinyin: '', task: 'general', json: false, file: null, baseUrl: undefined };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => { if (i + 1 >= argv.length) throw new Error(`${arg} needs a value`); return argv[++i]; };
    if (arg === '--language' || arg === '-l') out.language = next();
    else if (arg === '--pinyin') out.pinyin = next();
    else if (arg === '--task') out.task = next();
    else if (arg === '--file' || arg === '-f') out.file = next();
    else if (arg === '--base-url') out.baseUrl = next();
    else if (arg === '--json') out.json = true;
    else if (arg === '--help' || arg === '-h') out.help = true;
    else out.texts.push(arg);
  }
  return out;
}

function splitCsv(line) {
  const cells = []; let cell = ''; let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quoted) { if (c === '"' && line[i + 1] === '"') { cell += '"'; i++; } else if (c === '"') quoted = false; else cell += c; }
    else if (c === '"') quoted = true;
    else if (c === ',') { cells.push(cell); cell = ''; }
    else cell += c;
  }
  cells.push(cell);
  return cells.map(s => s.trim());
}

function itemsFrom(opts) {
  const items = opts.texts.map(text => ({ text, language: opts.language, pinyin: opts.pinyin }));
  if (opts.file) {
    const lines = readFileSync(opts.file, 'utf8').split(/\r?\n/).map(s => s.trim()).filter(s => s && !s.startsWith('#'));
    for (const line of lines) {
      if (opts.file.endsWith('.jsonl')) { let row; try { row = JSON.parse(line); } catch { throw new Error(`line ${lines.indexOf(line) + 1} is not valid JSON`); } items.push({ text: row.text || '', language: row.language || opts.language, pinyin: row.pinyin || '' }); }
      else if (opts.file.endsWith('.csv')) { const [text, language, pinyin] = splitCsv(line); if (text === 'text' && language === 'language') continue; items.push({ text, language: language || opts.language, pinyin: pinyin || '' }); }
      else items.push({ text: line, language: opts.language, pinyin: '' });
    }
  }
  return items;
}

async function main(argv = process.argv.slice(2), io = { log: console.log, error: console.error }, client = null) {
  let opts;
  try { opts = parseArgs(argv); } catch (e) { io.error(e.message); return 2; }
  if (opts.help) { io.log(readFileSync(__filename, 'utf8').split('*/')[0].replace(/^[\s\S]*?\/\*\n?/, '').replace(/^ \* ?/gm, '')); return 0; }
  let items;
  try { items = itemsFrom(opts); }
  catch (e) { io.error(`Cannot read ${opts.file}: ${e.code === 'ENOENT' ? 'file not found' : e.message}`); return 2; }
  if (!items.length) { io.error('Give a text or --file. See --help.'); return 2; }
  client = client || new TonePerfect({ baseUrl: opts.baseUrl, apiKey: 'unused-for-lint' });
  let failed = 0;
  for (const item of items) {
    let result;
    try { result = await client.lint(item.text, { language: item.language, pinyin: item.pinyin, task: opts.task }); }
    catch (e) { io.error(`network/API error: ${e.message}`); return 2; }
    if (!result.ok) failed++;
    if (opts.json) { io.log(JSON.stringify({ ...item, ...result })); continue; }
    io.log(`${result.ok ? 'ok   ' : 'ERROR'} [${item.language}] ${item.text}${item.pinyin ? ` (${item.pinyin})` : ''}`);
    for (const issue of result.issues || []) io.log(`      ${issue.severity}: ${issue.code}: ${issue.message}`);
  }
  if (!opts.json) io.log(`${items.length - failed}/${items.length} texts pass.`);
  return failed ? 1 : 0;
}

module.exports = { main, parseArgs, itemsFrom, splitCsv };
if (require.main === module) main().then(code => { process.exitCode = code; });
