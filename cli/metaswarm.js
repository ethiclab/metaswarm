#!/usr/bin/env node

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execSync } = require('child_process');

const PKG_ROOT = path.resolve(__dirname, '..');
const CWD = process.cwd();
const VERSION = require(path.join(PKG_ROOT, 'package.json')).version;

const { detectPlatforms, getSummary } = require(path.join(PKG_ROOT, 'lib', 'platform-detect'));
const OC_COMMANDS = ['setup', 'start-task', 'prime', 'review-design', 'design-review-gate', 'orchestrated-execution', 'self-reflect', 'handoff', 'pr-shepherd', 'brainstorm', 'update', 'status', 'handle-pr-comments', 'create-issue', 'external-tools-health'];
const OC_AGENTS = ['issue-orchestrator', 'architect-agent', 'product-manager-agent', 'designer-agent', 'security-design-agent', 'cto-agent', 'coder-agent', 'code-review-agent', 'researcher-agent', 'test-automator-agent', 'security-auditor-agent', 'knowledge-curator-agent', 'pr-shepherd-agent', 'release-engineer-agent', 'sre-agent', 'customer-service-agent', 'metrics-agent', 'swarm-coordinator-agent', 'slack-coordinator-agent'];

// --- Helpers ---

function warn(msg) {
  console.log(`  \u26a0  ${msg}`);
}

function info(msg) {
  console.log(`  \u2713  ${msg}`);
}

function skip(msg) {
  console.log(`  \u00b7  ${msg} (already exists, skipped)`);
}

function mkdirp(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

const METASWARM_MARKER = '## metaswarm';

// --- Platform-specific install functions ---

function installClaude() {
  console.log('\n  Installing for Claude Code...\n');
  try {
    console.log('  Running: claude plugin marketplace add dsifry/metaswarm-marketplace');
    execSync('claude plugin marketplace add dsifry/metaswarm-marketplace', { stdio: 'inherit' });
    console.log('  Running: claude plugin install metaswarm');
    execSync('claude plugin install metaswarm', { stdio: 'inherit' });
    info('Claude Code plugin installed');
    console.log('  Next: Open Claude Code and run /setup');
  } catch (e) {
    warn(`Claude Code install failed: ${e.message}`);
    console.log('  Try manually:');
    console.log('    claude plugin marketplace add dsifry/metaswarm-marketplace');
    console.log('    claude plugin install metaswarm');
  }
}

function installCodex() {
  console.log('\n  Installing for Codex CLI...\n');
  const installDir = path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'metaswarm');
  const skillsDir = path.join(os.homedir(), '.agents', 'skills');

  if (fs.existsSync(installDir)) {
    console.log(`  Updating existing installation at ${installDir}...`);
    try {
      execSync('git pull --rebase origin main', { cwd: installDir, stdio: 'inherit' });
      info('Updated metaswarm');
    } catch (e) {
      warn(`git pull failed: ${e.message || e}`);
      return;
    }
  } else {
    console.log(`  Cloning metaswarm to ${installDir}...`);
    mkdirp(path.dirname(installDir));
    try {
      execSync(`git clone https://github.com/dsifry/metaswarm.git "${installDir}"`, { stdio: 'inherit' });
      info('Cloned metaswarm');
    } catch (e) {
      warn(`Clone failed: ${e.message}`);
      return;
    }
  }

  // Symlink skills
  mkdirp(skillsDir);
  const skillsPath = path.join(installDir, 'skills');
  if (fs.existsSync(skillsPath)) {
    let linked = 0;
    for (const dir of fs.readdirSync(skillsPath)) {
      const srcDir = path.join(skillsPath, dir);
      if (!fs.statSync(srcDir).isDirectory()) continue;
      const linkName = `metaswarm-${dir}`;
      const linkPath = path.join(skillsDir, linkName);

      try {
        if (fs.lstatSync(linkPath).isSymbolicLink()) {
          fs.unlinkSync(linkPath);
        } else if (fs.existsSync(linkPath)) {
          warn(`${linkPath} exists as a directory, skipping`);
          continue;
        }
      } catch (e) {
        if (e.code !== 'ENOENT') warn(`Unexpected error checking ${linkPath}: ${e.message}`);
      }

      fs.symlinkSync(srcDir, linkPath);
      linked++;
    }
    info(`Linked ${linked} skills into ${skillsDir}`);
  }
  console.log('  Next: In your project, run $setup');
}

function installGemini() {
  console.log('\n  Installing for Gemini CLI...\n');
  try {
    console.log('  Running: gemini extensions install https://github.com/dsifry/metaswarm.git');
    execSync('gemini extensions install https://github.com/dsifry/metaswarm.git', { stdio: 'inherit' });
    info('Gemini CLI extension installed');
    console.log('  Next: In your project, run /metaswarm:setup');
  } catch (e) {
    warn(`Gemini CLI install failed: ${e.message}`);
    console.log('  Try manually:');
    console.log('    gemini extensions install https://github.com/dsifry/metaswarm.git');
  }
}

// --- OpenCode-specific setup ---

function setupOpenCode() {
  const opencodeDir = path.join(CWD, '.opencode');
  const commandsDir = path.join(opencodeDir, 'commands');
  const agentsDir = path.join(opencodeDir, 'agents');

  // 1. opencode.json (from template, with additive upgrade)
  const configPath = path.join(CWD, 'opencode.json');
  const configTemplate = path.join(PKG_ROOT, 'templates', 'opencode.json');

  if (!fs.existsSync(configPath)) {
    if (fs.existsSync(configTemplate)) {
      fs.copyFileSync(configTemplate, configPath);
      info('opencode.json (written from template)');
    } else {
      warn('opencode.json template not found');
    }
  } else if (fs.existsSync(configTemplate)) {
    // Additive upgrade: add commands/agents the template has that the
    // existing config lacks, and refresh template/description of entries
    // that still point at the standard metaswarm files. User-custom entries
    // (different template targets) are preserved untouched.
    try {
      const existing = JSON.parse(fs.readFileSync(configPath, 'utf-8'));
      const templ = JSON.parse(fs.readFileSync(configTemplate, 'utf-8'));
      let added = 0;
      let updated = 0;

      for (const section of ['command', 'agent']) {
        if (!existing[section]) existing[section] = {};
        if (!templ[section]) continue;
        for (const [name, def] of Object.entries(templ[section])) {
          if (!existing[section][name]) {
            existing[section][name] = def;
            added++;
          } else {
            const cur = existing[section][name];
            const isStandard = section === 'command'
              ? /^\{file:\.opencode\/commands\/[a-z0-9-]+\.md\}$/.test(cur.template || '')
              : /^\{file:\.opencode\/agents\/[a-z0-9-]+\.md\}$/.test(cur.prompt || '');
            if (isStandard) {
              let changed = false;
              if (cur.template && cur.template !== def.template) { cur.template = def.template; changed = true; }
              if (cur.prompt && cur.prompt !== def.prompt) { cur.prompt = def.prompt; changed = true; }
              if (changed) updated++;
            }
          }
        }
      }

      if (added > 0 || updated > 0) {
        fs.writeFileSync(configPath, JSON.stringify(existing, null, 2) + '\n', 'utf-8');
        info(`opencode.json (upgraded: +${added} added, ${updated} refreshed)`);
      } else {
        skip('opencode.json');
      }
    } catch (e) {
      warn(`opencode.json merge failed (${e.message}) — keeping existing file`);
    }
  } else {
    skip('opencode.json');
  }

  // 2. Command files
  mkdirp(commandsDir);
  for (const cmd of OC_COMMANDS) {
    const src = path.join(PKG_ROOT, 'commands', `${cmd}.md`);
    const dest = path.join(commandsDir, `${cmd}.md`);
    if (!fs.existsSync(dest)) {
      if (fs.existsSync(src)) {
        fs.copyFileSync(src, dest);
        info(`.opencode/commands/${cmd}.md`);
      } else {
        warn(`.opencode/commands/${cmd}.md — source not found at commands/${cmd}.md`);
      }
    } else {
      skip(`.opencode/commands/${cmd}.md`);
    }
  }

  // 3. Agent files
  mkdirp(agentsDir);
  for (const agent of OC_AGENTS) {
    const src = path.join(PKG_ROOT, 'agents', `${agent}.md`);
    const dest = path.join(agentsDir, `${agent}.md`);
    if (!fs.existsSync(dest)) {
      if (fs.existsSync(src)) {
        fs.copyFileSync(src, dest);
        info(`.opencode/agents/${agent}.md`);
      } else {
        warn(`.opencode/agents/${agent}.md — source not found at agents/${agent}.md`);
      }
    } else {
      skip(`.opencode/agents/${agent}.md`);
    }
  }

  // 4. Instruction file
  const instrPath = path.join(opencodeDir, 'OPENCODE.md');
  const instrTemplate = path.join(PKG_ROOT, 'templates', 'OPENCODE.md');
  if (!fs.existsSync(instrPath)) {
    if (fs.existsSync(instrTemplate)) {
      fs.copyFileSync(instrTemplate, instrPath);
      info('.opencode/OPENCODE.md (written from template)');
    } else {
      warn('.opencode/OPENCODE.md template not found');
    }
  } else {
    skip('.opencode/OPENCODE.md');
  }

  // 6. Session hook plugin (BEADS state preservation + setup warnings)
  const pluginsSource = path.join(PKG_ROOT, '.opencode', 'plugins');
  const pluginsDest = path.join(opencodeDir, 'plugins');
  if (fs.existsSync(pluginsSource)) {
    mkdirp(pluginsDest);
    for (const f of fs.readdirSync(pluginsSource)) {
      const dest = path.join(pluginsDest, f);
      if (!fs.existsSync(dest)) {
        fs.copyFileSync(path.join(pluginsSource, f), dest);
        info(`.opencode/plugins/${f}`);
      } else {
        skip(`.opencode/plugins/${f}`);
      }
    }
  }

  // 7. Skill definitions (SKILL.md discovery via .opencode/skills/<name>/)
  const skillsSource = path.join(PKG_ROOT, 'skills');
  const skillsDest = path.join(opencodeDir, 'skills');
  if (fs.existsSync(skillsSource)) {
    for (const skillName of fs.readdirSync(skillsSource)) {
      const skillDir = path.join(skillsSource, skillName);
      if (!fs.statSync(skillDir).isDirectory()) continue;
      if (!fs.existsSync(path.join(skillDir, 'SKILL.md'))) continue;
      const destSkillDir = path.join(skillsDest, skillName);
      if (!fs.existsSync(destSkillDir)) {
        fs.cpSync(skillDir, destSkillDir, { recursive: true });
        info(`.opencode/skills/${skillName}/`);
      } else {
        skip(`.opencode/skills/${skillName}/`);
      }
    }
  } else {
    warn('skills/ directory not found — skill discovery will be empty');
  }
}

// --- Project-level setup ---

function setupProject(platformFlag) {
  console.log(`\nmetaswarm v${VERSION} — project setup\n`);

  const platforms = detectPlatforms();
  const targetPlatforms = [];

  if (platformFlag === 'all') {
    // Explicit --all: target all platforms regardless of install status
    targetPlatforms.push('claude', 'codex', 'gemini', 'opencode');
  } else if (!platformFlag) {
    // No flag: auto-detect which are installed
    for (const [key, p] of Object.entries(platforms)) {
      if (p.installed) targetPlatforms.push(key);
    }
    if (targetPlatforms.length === 0) {
      targetPlatforms.push('claude'); // default
    }
  } else {
    targetPlatforms.push(platformFlag);
  }

  console.log(`  Setting up for: ${targetPlatforms.join(', ')}\n`);

  // Handle OpenCode separately (more files than just an instruction file)
  const hasOpenCode = targetPlatforms.includes('opencode');
  if (hasOpenCode) {
    setupOpenCode();
    console.log('');
  }

  for (const plat of targetPlatforms) {
    if (plat === 'opencode') continue; // already handled by setupOpenCode()
    const p = platforms[plat];
    const instrFile = p.instructionFile;
    const instrPath = path.join(CWD, instrFile);
    const templateDir = path.join(PKG_ROOT, 'templates');
    const fullTemplate = path.join(templateDir, instrFile);
    const appendTemplate = path.join(templateDir, `${path.basename(instrFile, '.md')}-append.md`);

    if (!fs.existsSync(instrPath)) {
      if (fs.existsSync(fullTemplate)) {
        fs.copyFileSync(fullTemplate, instrPath);
        info(`${instrFile} (written from template)`);
      } else {
        warn(`${instrFile} template not found`);
      }
    } else {
      const existing = fs.readFileSync(instrPath, 'utf-8');
      if (existing.includes(METASWARM_MARKER) || existing.includes('metaswarm')) {
        skip(`${instrFile} (metaswarm reference already present)`);
      } else if (fs.existsSync(appendTemplate)) {
        fs.appendFileSync(instrPath, '\n' + fs.readFileSync(appendTemplate, 'utf-8'));
        info(`${instrFile} (appended metaswarm section)`);
      }
    }
  }

  // Coverage thresholds
  const coveragePath = path.join(CWD, '.coverage-thresholds.json');
  const coverageTemplate = path.join(PKG_ROOT, 'templates', 'coverage-thresholds.json');
  if (!fs.existsSync(coveragePath) && fs.existsSync(coverageTemplate)) {
    fs.copyFileSync(coverageTemplate, coveragePath);
    info('.coverage-thresholds.json');
  } else if (fs.existsSync(coveragePath)) {
    skip('.coverage-thresholds.json');
  }

  console.log('\n  Project setup complete!');
  for (const plat of targetPlatforms) {
    if (plat === 'opencode') {
      console.log('  OpenCode: Config written. Run `opencode` to start using metaswarm commands.');
    } else {
      const p = platforms[plat];
      console.log(`  ${p.name}: Run ${p.setupCommand} for full interactive configuration`);
    }
  }
  console.log('');
}

// --- Commands ---

function printHelp() {
  console.log(`
metaswarm v${VERSION} — Cross-platform installer

Usage:
  metaswarm init [flags]        Install metaswarm for detected CLI tools
  metaswarm setup [flags]       Set up metaswarm in the current project
  metaswarm detect              Show which CLI tools are installed
  metaswarm --help              Show this help
  metaswarm --version           Show version

Init flags:
  --claude            Install for Claude Code only
  --codex             Install for Codex CLI only
  --gemini            Install for Gemini CLI only
  --opencode          Point to project setup (OpenCode needs no global install)
  (no flag)           Auto-detect installed CLIs and install for all

Setup flags:
  --claude            Write CLAUDE.md only
  --codex             Write AGENTS.md only
  --gemini            Write GEMINI.md only
  --opencode          Generate opencode.json, copy commands and agents
  --all               Write configs for all platforms
  (no flag)           Auto-detect installed CLIs

Examples:
  npx metaswarm init            Auto-detect and install for all CLIs
  npx metaswarm init --codex    Install for Codex CLI only
  npx metaswarm setup           Set up project for detected CLIs
  npx metaswarm setup --opencode  Set up project for OpenCode only
  npx metaswarm detect          Show which CLIs are available
`);
}

async function initCommand(args) {
  const flags = new Set(args);
  const platforms = detectPlatforms();

  console.log(`\nmetaswarm v${VERSION} — init\n`);
  console.log('  Detected CLI tools:\n');
  console.log(getSummary(platforms));
  console.log('');

  // Determine which platforms to install for
  const explicit = flags.has('--claude') || flags.has('--codex') || flags.has('--gemini') || flags.has('--opencode');

  if (flags.has('--claude') || (!explicit && platforms.claude.installed)) {
    installClaude();
  }

  if (flags.has('--codex') || (!explicit && platforms.codex.installed)) {
    installCodex();
  }

  if (flags.has('--gemini') || (!explicit && platforms.gemini.installed)) {
    installGemini();
  }

  if (flags.has('--opencode')) {
    info('OpenCode: no marketplace install needed — run `npx metaswarm setup --opencode` in your project');
  } else if (!explicit && platforms.opencode.installed) {
    info('OpenCode detected — run `npx metaswarm setup --opencode` in your project');
  }

  if (!explicit) {
    const installed = Object.values(platforms).filter(p => p.installed);
    if (installed.length === 0) {
      console.log('\n  No supported CLI tools detected.');
      console.log('  Install one of: claude, codex, gemini, opencode');
      console.log('  Then re-run: npx metaswarm init\n');
    }
  }

  console.log('\n  Init complete! Next: run `npx metaswarm setup` in your project.\n');
}

function detectCommand() {
  const platforms = detectPlatforms();
  console.log(`\nmetaswarm v${VERSION} — platform detection\n`);
  console.log(getSummary(platforms));
  console.log('');

  const installed = Object.entries(platforms).filter(([, p]) => p.installed);
  if (installed.length > 0) {
    console.log('  Install metaswarm:');
    for (const [, p] of installed) {
      console.log(`    ${p.name}: ${p.installCommand}`);
    }
  }
  console.log('');
}

// --- Main ---

const args = process.argv.slice(2);
const cmd = args[0];

if (cmd === 'init') {
  initCommand(args.slice(1));
} else if (cmd === 'setup') {
  const flags = new Set(args.slice(1));
  let platformFlag = null;
  if (flags.has('--claude')) platformFlag = 'claude';
  else if (flags.has('--codex')) platformFlag = 'codex';
  else if (flags.has('--gemini')) platformFlag = 'gemini';
  else if (flags.has('--opencode')) platformFlag = 'opencode';
  else if (flags.has('--all')) platformFlag = 'all';
  setupProject(platformFlag);
} else if (cmd === 'detect') {
  detectCommand();
} else if (cmd === '--version' || cmd === '-v') {
  console.log(VERSION);
} else {
  printHelp();
}
