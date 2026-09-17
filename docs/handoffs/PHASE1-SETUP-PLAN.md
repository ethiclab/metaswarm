# OpenCode Phase 1: Setup & Code Review Automation

**Date**: 2026-06-30  
**Current Branch**: `feat/opencode-support` (PR #47 in DRAFT)  
**Goal**: Consolidate PR #47, enable code review automation, start Phase 1 fresh

---

## Phase A: Consolidate PR #47 Work

### Step 1: Extract Learnings (In Progress)
- **Command**: `/self-reflect`
- **What it does**: Analyzes all 10 commits on `feat/opencode-support` to extract reusable insights
- **Output**: Updates `.beads/knowledge/` with learnings from PR #47 review process
- **Why**: Captures CodeRabbit/Greptile feedback patterns so we don't repeat mistakes

### Step 2: Squash Commits into One
```bash
# Squash last 10 commits into 1
git rebase -i HEAD~10

# In the editor, keep first commit as "pick", change rest to "squash"
# This combines all changes into one commit:
# "feat: add OpenCode as a supported platform (Phase 1 POC)"

git push fork feat/opencode-support --force
```

### Step 3: Manage Branches
**Option A (Recommended)**: Keep remote branch for historical reference
- Remote stays: `origin feat/opencode-support` (for PR history)
- Create local: `feat/opencode-phase1` for Phase 1 work

**Option B**: Delete remote to clean slate
```bash
git push fork --delete feat/opencode-support
```

---

## Phase B: Install Code Review Automation

### What These Tools Do

| Tool | Purpose | Learn |
|------|---------|-------|
| **CodeRabbit** | AI-powered line-by-line code review | Detailed feedback on every PR |
| **Greptile** | Intelligent code search & summaries | Quick overview of changes |
| **GitHub Actions** | Run tests & validation (already setup) | `.github/workflows/ci.yml` |

### Installation Steps

#### 1. CodeRabbit Setup (5 minutes)
1. Go to https://coderabbit.ai
2. Click "Sign in with GitHub"
3. Select your fork (`ethiclab/metaswarm`)
4. Authorize the app
5. **That's it** — CodeRabbit now auto-reviews every PR

**Optional**: Create `.coderabbitai.yaml` in fork root to customize rules:
```yaml
# .coderabbitai.yaml
language: en
early_access: false
rules:
  - type: comment
    pattern: "TODO|FIXME"
    message: "Consider resolving this before merging"
security:
  review: true
```

#### 2. Greptile Setup (5 minutes)
1. Go to https://www.greptile.com
2. Click "Get Started" or "Install"
3. Sign in with GitHub
4. Select your fork (`ethiclab/metaswarm`)
5. Authorize the app
6. **Done** — Greptile now provides summaries on every PR

### Verification

After installing both:
1. Create a test PR from `feat/opencode-phase1` branch
2. Make a small change (e.g., update README)
3. Push and create PR to `fork:main`
4. Within 30-60 seconds, you should see:
   - CodeRabbit commenting with detailed review
   - Greptile providing a summary comment

---

## Phase C: Start Phase 1 Work

### Create Local Branch for Phase 1
```bash
# From feat/opencode-support (after squash)
git checkout -b feat/opencode-phase1
```

### Phase 1 Scope (13 Commands, 19 Agents)
See `memory/project_opencode_status.md` for complete checklist:
- Generate all 13 command files
- Register all 19 agents
- Generate all 19 agent prompts
- Verify full coverage
- Update templates and documentation

### Code Review Workflow in Phase 1

**For each work unit**:
1. Create feature branch from `feat/opencode-phase1`
2. Make changes + write tests
3. Push to fork and create PR to `fork:main`
4. **CodeRabbit** provides detailed review (20-40 seconds)
5. **Greptile** provides summary (30-60 seconds)
6. **GitHub Actions CI** runs tests (from `.github/workflows/ci.yml`)
7. Fix feedback, push changes
8. Once all checks pass → merge to `feat/opencode-phase1`
9. Repeat for next work unit

---

## Learning Goals

By the end of this setup, you'll understand:

✓ How AI code review tools (CodeRabbit, Greptile) improve PR quality  
✓ How to interpret their feedback patterns  
✓ How to apply feedback consistently across multiple PRs  
✓ How GitHub Actions integrates with code review  
✓ How to configure custom review rules (`.coderabbitai.yaml`)  

---

## Timeline

- **Self-reflect**: In progress (5-10 min)
- **Squash commits**: 2 min
- **CodeRabbit setup**: 5 min
- **Greptile setup**: 5 min
- **Verification test PR**: 10 min
- **Start Phase 1**: Ready to go

**Total**: ~30 minutes to full setup

---

## Next Steps

1. Wait for `/self-reflect` to complete
2. Execute squash and branch setup
3. Install CodeRabbit and Greptile (via web, takes 10 min)
4. Create test PR to verify both work
5. Begin Phase 1 implementation with full code review automation
