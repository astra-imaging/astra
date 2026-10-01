param(
    [string]$Repo = "",
    [string]$AgentBranch = "agent/astra-dev",
    [bool]$AutoPush = $true,
    [int]$MaxReviewRounds = 3,
    [bool]$RunCliSmokeTest = $true
)

$ErrorActionPreference = "Stop"

# ============================================================
# Resolve paths
# ============================================================

$ScriptPath = $MyInvocation.MyCommand.Path
$AgentDir = Split-Path -Parent $ScriptPath

if ([string]::IsNullOrWhiteSpace($Repo)) {
    $Repo = Split-Path -Parent $AgentDir
}

$Repo = (Resolve-Path $Repo).Path
$AgentDir = (Resolve-Path $AgentDir).Path

$TaskFile = Join-Path $AgentDir "TASK.md"
$ReviewFile = Join-Path $AgentDir "REVIEW.md"
$RoadmapFile = Join-Path $AgentDir "ROADMAP.md"
$StopFile = Join-Path $AgentDir "STOP"
$LogDir = Join-Path $AgentDir "logs"

$PlanMarkdown = Join-Path $AgentDir "ASTRA_PROJECT_PLAN.md"
$PlanPdf = Join-Path $AgentDir "ASTRA_PROJECT_PLAN.pdf"

if (Test-Path $PlanMarkdown) {
    $PlanFile = $PlanMarkdown
}
elseif (Test-Path $PlanPdf) {
    $PlanFile = $PlanPdf
}
else {
    throw @"
No Astra project plan found.

Add one of:

.agent\ASTRA_PROJECT_PLAN.md
.agent\ASTRA_PROJECT_PLAN.pdf
"@
}

if (!(Test-Path $RoadmapFile)) {
    throw "Missing .agent\ROADMAP.md"
}

if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

Set-Location $Repo


# ============================================================
# Helpers
# ============================================================

function Write-Section {
    param([string]$Text)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkGray
}


function Check-Stop {
    if (Test-Path $StopFile) {
        Write-Section "STOP REQUESTED"
        Write-Host ".agent\STOP detected. Exiting cleanly."
        exit 0
    }
}


function Assert-CommandExists {
    param([string]$Command)

    if (!(Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required command '$Command' was not found in PATH."
    }
}


function Get-NonAgentChanges {
    $lines = @(git status --porcelain)

    $filtered = @()

    foreach ($line in $lines) {

        # Ignore all supervisor-control files.
        if ($line -match '\.agent[/\\]') {
            continue
        }

        $filtered += $line
    }

    return $filtered
}


function Assert-CleanSourceTree {
    $changes = @(Get-NonAgentChanges)

    if ($changes.Count -gt 0) {
        Write-Host ""
        Write-Host "Source tree contains uncommitted changes:" -ForegroundColor Yellow
        $changes | ForEach-Object { Write-Host $_ }

        throw @"
The supervisor will not start with existing source changes.

Commit or stash the current Astra work first.
.agent files are ignored by this check.
"@
    }
}


function Write-Log {
    param(
        [string]$Prefix,
        [string]$Content
    )

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $path = Join-Path $LogDir "$timestamp-$Prefix.log"

    Set-Content `
        -Path $path `
        -Value $Content `
        -Encoding UTF8
}


# ============================================================
# Claude
# ============================================================

function Run-Claude {
    param([string]$Prompt)

    Write-Section "CLAUDE"

    Check-Stop

    $output = @(
        $Prompt |
            & claude `
                -p `
                --output-format text `
                --dangerously-skip-permissions `
                2>&1
    )

    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine

    Write-Host $text

    Write-Log "claude" $text

    if ($exitCode -ne 0) {
        throw "Claude failed with exit code $exitCode."
    }

    return $text
}


# ============================================================
# Codex
#
# Important:
# Your codex-cli 0.159.3 rejected --full-auto.
#
# We therefore use plain:
#
#   codex exec -
#
# Codex does NOT edit code in this workflow.
# It plans, reviews and writes commit messages.
# Claude is the implementation agent.
# ============================================================

function Run-CodexCapture {
    param([string]$Prompt)

    Write-Section "CODEX"

    Check-Stop

    $output = @(
        $Prompt |
            & codex exec - `
                2>&1
    )

    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine

    Write-Host $text

    Write-Log "codex" $text

    if ($exitCode -ne 0) {
        throw "Codex failed with exit code $exitCode."
    }

    return $text
}


# ============================================================
# Build / test validation
# ============================================================

function Run-Build {
    Write-Section "DOTNET BUILD"

    $output = @(
        & dotnet build --no-incremental 2>&1
    )

    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine

    Write-Host $text
    Write-Log "build" $text

    if ($exitCode -ne 0) {
        return $false
    }

    # Reject common compiler/analyzer/MSBuild/NuGet warnings.
    if ($text -match '(?im)\bwarning\s+(CS|CA|NU|NETSDK|MSB)\d+') {
        Write-Host "Build contains warnings." -ForegroundColor Red
        return $false
    }

    # Also catch final MSBuild warning count if present.
    if ($text -match '(?im)\b[1-9][0-9]*\s+Warning\(s\)') {
        Write-Host "Build contains warnings." -ForegroundColor Red
        return $false
    }

    return $true
}


function Run-Tests {
    Write-Section "DOTNET TEST"

    $output = @(
        & dotnet test 2>&1
    )

    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine

    Write-Host $text
    Write-Log "test" $text

    if ($exitCode -ne 0) {
        return $false
    }

    return $true
}


function Run-Validation {

    Check-Stop

    if (!(Run-Build)) {
        return $false
    }

    Check-Stop

    if (!(Run-Tests)) {
        return $false
    }

    return $true
}


# ============================================================
# Git branch
# ============================================================

function Ensure-AgentBranch {

    Write-Section "GIT BRANCH"

    $current = (git branch --show-current).Trim()

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to determine current Git branch."
    }

    if ($current -eq $AgentBranch) {
        Write-Host "Already on $AgentBranch"
        return
    }

    git show-ref --verify --quiet "refs/heads/$AgentBranch"

    if ($LASTEXITCODE -eq 0) {

        Write-Host "Switching to existing branch $AgentBranch"

        git switch $AgentBranch

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to switch to $AgentBranch"
        }
    }
    else {

        Write-Host "Creating branch $AgentBranch"

        git switch -c $AgentBranch

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to create $AgentBranch"
        }
    }
}


# ============================================================
# CLI smoke tests
# ============================================================

function Test-AgentClis {

    if (!$RunCliSmokeTest) {
        return
    }

    Write-Section "CLI PREFLIGHT"

    Write-Host "Testing Claude authentication..."

    $claudeOutput = @(
        "Reply with exactly OK." |
            & claude -p --output-format text 2>&1
    )

    $claudeExit = $LASTEXITCODE

    if ($claudeExit -ne 0) {
        $text = $claudeOutput -join [Environment]::NewLine
        Write-Host $text

        throw @"
Claude CLI authentication failed.

Run Claude manually and authenticate first, for example:

    claude

or use the authentication command supported by your Claude CLI.
"@
    }

    Write-Host "Claude: OK" -ForegroundColor Green


    Write-Host "Testing Codex..."

    $codexOutput = @(
        "Reply with exactly OK. Do not modify any files." |
            & codex exec - 2>&1
    )

    $codexExit = $LASTEXITCODE

    if ($codexExit -ne 0) {
        $text = $codexOutput -join [Environment]::NewLine
        Write-Host $text

        throw "Codex CLI preflight failed."
    }

    Write-Host "Codex: OK" -ForegroundColor Green
}


# ============================================================
# Planner
# ============================================================

function Plan-NextSlice {

    Write-Section "PLANNING NEXT ASTRA SLICE"

    Check-Stop

    $relativePlan = $PlanFile.Replace($Repo + "\", "").Replace("\", "/")

    $prompt = @"
You are the architecture planner for the Astra astrophotography sequencer.

You are working inside the Astra repository.

Read and inspect:

- $relativePlan
- .agent/ROADMAP.md
- the current repository
- recent git history
- existing tests
- current architecture

IMPORTANT AUTHORITY ORDER:

1. Current repository state is the source of truth for what already exists.
2. .agent/ROADMAP.md describes current implementation priorities.
3. $relativePlan is the long-term product and architecture reference.

The master project plan is NOT a literal unchecked todo list.

Many capabilities from the original plan may already have been implemented
earlier than the original phase ordering.

Never reimplement functionality that already exists.

Astra product principles include:

- Auto-first, but never auto-only.
- Automate what can be measured.
- Automation must not remove control.
- Expose confidence, not fake certainty.
- Multi-camera / multi-rig are first-class concepts.
- The sequencer owns the imaging session.
- Runtime architecture should remain suitable for future headless operation.
- Current implementation scope is Windows standalone first.

Before selecting the next task:

1. Inspect the current repo.
2. Inspect recent commits.
3. Determine what is already implemented.
4. Compare the real implementation against the long-term plan.
5. Identify the smallest meaningful architectural/product gap.
6. Prefer foundational correctness over flashy features.
7. Choose exactly ONE coherent implementation slice.

DO NOT modify any files.

DO NOT implement anything.

DO NOT commit.

Return ONLY a complete implementation task in Markdown.

The task must include:

# Goal

# Current relevant architecture

# Requirements

# Tests

# Explicit non-goals

# Validation

Validation must require:

dotnet build --no-incremental
dotnet test

with:
- zero warnings
- zero errors
- all tests passing

The task should be sufficiently detailed for another coding agent to implement
without inventing major architecture decisions.

Do not wrap your response in a Markdown code fence.
"@

    $task = Run-CodexCapture $prompt

    if ([string]::IsNullOrWhiteSpace($task)) {
        throw "Planner returned an empty task."
    }

    Set-Content `
        -Path $TaskFile `
        -Value $task `
        -Encoding UTF8

    Write-Section "TASK CREATED"
    Write-Host $task
}


# ============================================================
# Builder
# ============================================================

function Implement-CurrentTask {

    Write-Section "IMPLEMENTING CURRENT TASK"

    Check-Stop

    $relativePlan = $PlanFile.Replace($Repo + "\", "").Replace("\", "/")

    $prompt = @"
You are the primary implementation engineer for the Astra astrophotography
sequencer.

Read before making changes:

- $relativePlan
- .agent/ROADMAP.md
- .agent/TASK.md
- current repository code
- relevant tests
- recent git history

The repository is the source of truth for what is currently implemented.

Implement EXACTLY the task in .agent/TASK.md.

Engineering rules:

- Inspect existing architecture before editing.
- Preserve established naming and patterns where sensible.
- Do not broaden scope.
- Do not implement the next roadmap feature.
- Do not perform unrelated refactors.
- Keep Core free from UI/platform-specific dependencies.
- Preserve runtime correctness under cancellation and concurrency.
- Respect ResourceManager and SafePointCoordinator semantics where relevant.
- Keep definition/configuration state separate from runtime execution state.
- Add focused tests for new behavior.
- Avoid fragile timing-based concurrency tests where synchronization primitives
  can be used instead.
- Keep all existing tests passing.
- Zero build warnings are allowed.

Do NOT modify:

- .agent/ROADMAP.md
- the Astra master project plan
- .agent/REVIEW.md

Do NOT choose the next task.

Do NOT commit.

When implementation is complete run:

dotnet build --no-incremental
dotnet test

Fix all failures and warnings before finishing.

At the end, report concisely:
- files changed
- behavior implemented
- test results
- architectural concerns

Do not commit.
"@

    Run-Claude $prompt | Out-Null
}


# ============================================================
# Build-failure repair
# ============================================================

function Repair-ValidationFailure {

    Write-Section "CLAUDE VALIDATION REPAIR"

    $prompt = @"
The current Astra task does not pass the required validation.

Read:

- .agent/TASK.md
- current git diff
- build/test failures

Run:

dotnet build --no-incremental
dotnet test

Fix ONLY issues related to the current task.

Requirements:

- zero warnings
- zero errors
- all tests passing
- no scope expansion
- no unrelated refactors
- no new feature beyond TASK.md

Do not commit.
"@

    Run-Claude $prompt | Out-Null
}


# ============================================================
# Review
# ============================================================

function Review-CurrentTask {

    Write-Section "CODEX REVIEW"

    Check-Stop

    $relativePlan = $PlanFile.Replace($Repo + "\", "").Replace("\", "/")

    $prompt = @"
You are the senior code/architecture reviewer for Astra.

DO NOT modify files.

Read:

- $relativePlan
- .agent/ROADMAP.md
- .agent/TASK.md
- current git diff
- relevant existing code
- relevant tests
- recent git history

Review the implementation against TASK.md and Astra's existing architecture.

Pay particular attention to:

- correctness
- concurrency
- cancellation semantics
- async behavior
- ResourceManager lifetime/locking
- SafePoint coordination where relevant
- state/event consistency
- sequence execution semantics
- thread safety
- resource leaks
- event subscription leaks
- error propagation
- regression risk
- unnecessary abstractions
- scope creep
- tests that prove behavior rather than implementation details

Also verify that the implementation does not accidentally undermine future:

- multi-camera / multi-rig
- headless runtime
- remote device proxies
- plugin boundaries

Do not demand speculative abstractions merely because they may be useful later.

Prefer the smallest architecture appropriate for the current slice.

Return EXACTLY one of these forms:

STATUS: PASS

Summary:
<short summary>

or:

STATUS: CHANGES_REQUIRED

Findings:
1. <specific actionable problem>
2. <specific actionable problem>

Do not wrap the response in a Markdown code fence.

Do not implement fixes.
Do not commit.
"@

    $review = Run-CodexCapture $prompt

    Set-Content `
        -Path $ReviewFile `
        -Value $review `
        -Encoding UTF8

    return $review
}


# ============================================================
# Review repair
# ============================================================

function Repair-ReviewFindings {

    Write-Section "CLAUDE REVIEW REPAIR"

    $prompt = @"
The Astra reviewer requested changes to the current task.

Read:

- .agent/TASK.md
- .agent/REVIEW.md
- current git diff
- relevant existing architecture

Address every valid review finding.

Rules:

- stay within the current TASK.md scope
- do not add the next feature
- do not perform unrelated refactors
- preserve existing public behavior unless correction is required
- add or adjust tests where necessary

Run:

dotnet build --no-incremental
dotnet test

Require:
- zero warnings
- zero errors
- all tests green

Do not commit.
"@

    Run-Claude $prompt | Out-Null
}


# ============================================================
# Commit message
# ============================================================

function Get-CommitMessage {

    Write-Section "GENERATING COMMIT MESSAGE"

    $prompt = @"
Read:

- .agent/TASK.md
- the currently staged git diff

Return ONLY one concise Conventional Commit message.

Use forms such as:

feat: add guiding abstraction
feat: add coordinated dithering
fix: correct safe point cancellation
refactor: separate sequence execution state

No Markdown.
No quotes.
No explanation.
One line only.
"@

    $raw = Run-CodexCapture $prompt

    $lines = @(
        $raw -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { ![string]::IsNullOrWhiteSpace($_) }
    )

    if ($lines.Count -eq 0) {
        throw "Codex did not produce a commit message."
    }

    $message = $lines[0]
    $message = $message.Trim('`')
    $message = $message.Trim('"')
    $message = $message.Trim("'")

    return $message
}


# ============================================================
# Commit
# ============================================================

function Commit-CurrentSlice {

    Write-Section "COMMITTING SLICE"

    # Stage everything first.
    git add -A

    if ($LASTEXITCODE -ne 0) {
        throw "git add failed."
    }

    # Never auto-commit supervisor control files.
    git reset -- .agent 2>$null

    $staged = @(git diff --cached --name-only)

    if ($staged.Count -eq 0) {
        throw "Task produced no staged source changes."
    }

    Write-Host ""
    Write-Host "Staged files:"
    $staged | ForEach-Object { Write-Host "  $_" }

    $message = Get-CommitMessage

    Write-Host ""
    Write-Host "Commit message: $message" -ForegroundColor Green

    git commit -m $message

    if ($LASTEXITCODE -ne 0) {
        throw "Git commit failed."
    }

    Write-Host ""
    git log -1 --oneline
}


# ============================================================
# Push
# ============================================================

function Push-AgentBranch {

    if (!$AutoPush) {
        return
    }

    Write-Section "PUSHING"

    $branch = (git branch --show-current).Trim()

    git push -u origin $branch

    if ($LASTEXITCODE -ne 0) {
        throw "Git push failed."
    }
}


# ============================================================
# Cycle cleanup
# ============================================================

function Clear-CycleFiles {

    Remove-Item $TaskFile -ErrorAction SilentlyContinue
    Remove-Item $ReviewFile -ErrorAction SilentlyContinue
}


# ============================================================
# Startup
# ============================================================

Write-Section "ASTRA AUTONOMOUS SUPERVISOR"

Write-Host "Repository : $Repo"
Write-Host "Agent dir  : $AgentDir"
Write-Host "Plan       : $PlanFile"
Write-Host "Roadmap    : $RoadmapFile"
Write-Host "Branch     : $AgentBranch"
Write-Host "Auto push  : $AutoPush"
Write-Host ""

Assert-CommandExists "git"
Assert-CommandExists "dotnet"
Assert-CommandExists "claude"
Assert-CommandExists "codex"

Check-Stop

Assert-CleanSourceTree

Ensure-AgentBranch

Test-AgentClis


# ============================================================
# Main autonomous loop
# ============================================================

$cycle = 0

while ($true) {

    $cycle++

    Write-Section "ASTRA AGENT CYCLE $cycle"

    Check-Stop


    # --------------------------------------------------------
    # 1. Plan
    # --------------------------------------------------------

    Plan-NextSlice

    Check-Stop


    # --------------------------------------------------------
    # 2. Implement
    # --------------------------------------------------------

    Implement-CurrentTask

    Check-Stop


    # --------------------------------------------------------
    # 3. Hard local validation
    # --------------------------------------------------------

    if (!(Run-Validation)) {

        Repair-ValidationFailure

        Check-Stop

        if (!(Run-Validation)) {
            throw @"
Validation still fails after Claude repair.

Stopping for human inspection.
"@
        }
    }


    # --------------------------------------------------------
    # 4. Review / repair loop
    # --------------------------------------------------------

    $passedReview = $false

    for ($reviewRound = 1; $reviewRound -le $MaxReviewRounds; $reviewRound++) {

        Write-Section "REVIEW ROUND $reviewRound / $MaxReviewRounds"

        Remove-Item $ReviewFile -ErrorAction SilentlyContinue

        $review = Review-CurrentTask

        Check-Stop

        if ($review -match '(?im)^\s*STATUS:\s*PASS\s*$') {

            Write-Host ""
            Write-Host "Review passed." -ForegroundColor Green

            $passedReview = $true
            break
        }

        if ($review -match '(?im)^\s*STATUS:\s*CHANGES_REQUIRED\s*$') {

            Write-Host ""
            Write-Host "Changes required." -ForegroundColor Yellow

            Repair-ReviewFindings

            Check-Stop

            if (!(Run-Validation)) {

                Repair-ValidationFailure

                if (!(Run-Validation)) {
                    throw "Validation failed after review repair."
                }
            }

            continue
        }

        throw @"
Codex review did not contain a valid status.

Expected:

STATUS: PASS

or:

STATUS: CHANGES_REQUIRED
"@
    }


    if (!$passedReview) {
        throw @"
Review still has unresolved findings after $MaxReviewRounds rounds.

Stopping for human inspection.
"@
    }


    # --------------------------------------------------------
    # 5. Final validation
    # --------------------------------------------------------

    Write-Section "FINAL VALIDATION"

    if (!(Run-Validation)) {
        throw "Final validation failed."
    }


    # --------------------------------------------------------
    # 6. Commit
    # --------------------------------------------------------

    Commit-CurrentSlice


    # --------------------------------------------------------
    # 7. Push
    # --------------------------------------------------------

    Push-AgentBranch


    # --------------------------------------------------------
    # 8. Cleanup
    # --------------------------------------------------------

    Clear-CycleFiles


    Write-Section "CYCLE $cycle COMPLETE"

    Write-Host "Sleeping for 2 seconds before planning next slice..."
    Start-Sleep -Seconds 2
}