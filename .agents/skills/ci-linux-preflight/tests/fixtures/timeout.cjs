const { spawnSync } = require('node:child_process');
const args = process.argv.slice(2);
args.shift();
const seconds = Number(args.shift());
const command = args.shift();
if (process.env.FAKE_TIMEOUT_SECONDS) {
  require('node:fs').writeFileSync(process.env.FAKE_TIMEOUT_SECONDS, String(seconds));
}
const result = spawnSync(command, args, { stdio: 'inherit', timeout: seconds * 1000 });
process.exit(result.error?.code === 'ETIMEDOUT' ? 124 : result.status ?? 75);
