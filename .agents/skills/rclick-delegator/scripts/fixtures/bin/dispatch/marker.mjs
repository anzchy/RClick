import fs from 'node:fs';
import path from 'node:path';
const [home, worktree, issue, task, handoff, branch] = process.argv.slice(2);
const out = path.join(home, '.build/rclick-verify/target-worktree');
fs.mkdirSync(path.dirname(out), {recursive:true});
fs.writeFileSync(out, JSON.stringify({worktree, branch, issue:Number(issue), task, handoff}));
fs.writeFileSync(path.join(home, 'marker-used'), 'yes');
