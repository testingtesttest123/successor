// Executes the pinned upstream method through a exposing subclass. No provider calls.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

const [sourcePath, fixturePath, outputPath, mode] = process.argv.slice(2);
if (!sourcePath || !fixturePath || !outputPath) {
  throw new Error('usage: node lcm_kv_fixture_oracle.mjs PINNED_SOURCE FIXTURES OUTPUT');
}
const source = readFileSync(sourcePath, 'utf8');
const fixtures = JSON.parse(readFileSync(fixturePath, 'utf8'));
const hash = value => createHash('sha256').update(value).digest('hex');
if (hash(source) !== fixtures.provenance.source_sha256) {
  throw new Error('upstream source SHA-256 mismatch');
}
const start = source.indexOf('  protected static computeStaticSalience(msg: StoredMessage): number {');
const end = source.indexOf('\n  /** Memoized true render cost', start);
if (start < 0 || end < 0) throw new Error('pinned upstream method boundaries changed');
const method = source.slice(start, end).trimEnd();
if (hash(method) !== fixtures.provenance.method_sha256) {
  throw new Error('upstream static method SHA-256 mismatch');
}
const code = stripTypeScriptTypes(`class Upstream {\n${method}\n}\n`);
const Upstream = new Function(`${code}; return Upstream;`)();
class Exposed extends Upstream {
  static score(content) { return super.computeStaticSalience({ content }); }
}
const results = fixtures.cases.map(test => {
  const blocks = test.blocks.map(block => {
    if (!Object.hasOwn(block, 'native_arguments')) return block;
    let input;
    try { input = JSON.parse(block.native_arguments); }
    catch { input = block.native_arguments; }
    return { ...block, input };
  });
  const actual = Exposed.score(blocks);
  if (mode === '--record') test.expected_score = actual;
  if (!Number.isFinite(test.expected_score)) throw new Error(`${test.name}: missing expected score`);
  if (Math.abs(actual - test.expected_score) > 1e-12) {
    throw new Error(`${test.name}: recorded score ${test.expected_score}, executed upstream ${actual}`);
  }
  return { name: test.name, score: actual };
});
if (mode === '--record') writeFileSync(fixturePath, JSON.stringify(fixtures, null, 2) + '\n');
writeFileSync(outputPath, JSON.stringify({ provenance: fixtures.provenance, results }, null, 2) + '\n');
console.log(`Executed pinned upstream salience method: ${results.length} fixtures passed`);
