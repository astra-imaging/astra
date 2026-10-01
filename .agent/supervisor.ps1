param(
    [string]$Repo = "C:\Users\juli\source\repos\astra"
)

$ErrorActionPreference = "Stop"

Set-Location $Repo

$AgentDir = Join-Path $Repo ".agent"
$TaskFile = Join-Path $AgentDir "TASK.md"
$ReviewFile = Join-Path $AgentDir "REVIEW.md"
$RoadmapFile = Join-Path $AgentDir "ROADMAP.md"
$StopFile = Join-Path $AgentDir "STOP"

function Write-Section($text) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host $text
    Write-Host "============================================================"
}

function Check-Stop {
    if (Test-Path $StopFile) {
        Write-Host "STOP file detected. Exiting."
        exit 0
    }
}

function Run-Validation {
    Write-Section "BUILD"

    dotnet build --no-incremental
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    Write-Section "TEST"

    dotnet test
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return $true
}

function Run-Claude($prompt) {
    Write-Section "CLAUDE"

    $prompt | claude -p --output-format text --dangerously-skip-permissions

    if ($LASTEXITCODE -ne 0) {
        throw "Claude failed with exit code $LASTEXITCODE"
    }
}

function Run-Codex($prompt) {
    Write-Section "CODEX"

    $prompt | codex exec -

    if ($LASTEXITCODE -ne 0) {
        throw "Codex failed with exit code $LASTEXITCODE"
    }
}

Write-Section "ASTRA AUTONOMOUS SUPERVISOR"

while ($true) {

    Check-Stop

    # ---------------------------------------------------------
    # 1. CODEX PLANS NEXT TASK
    # ---------------------------------------------------------

    Write-Section "PLANNING NEXT SLICE"

    $plannerPrompt = @"
You are the architecture planner for the Astra astrophotography sequencer.

Read:
- .agent/ROADMAP.md
- the current repository
- git log
- existing architecture and tests

Choose exactly ONE next coherent implementation slice.

Rules:
- do not broaden scope
- do not implement multiple roadmap phases
- prioritize correctness and architecture
- respect the Do Not Implement Yet section
- do not modify source code

Write the full implementation task into:

.agent/TASK.md

The task must include:
- goal
- current relevant architecture
- requirements
- tests
- explicit non-goals
- validation:
  dotnet build --no-incremental
  dotnet test

Do not implement the task.
"@

    Run-Codex $plannerPrompt

    Check-Stop

    if (!(Test-Path $TaskFile)) {
        throw "Planner did not create TASK.md"
    }

    # ---------------------------------------------------------
    # 2. CLAUDE IMPLEMENTS
    # ---------------------------------------------------------

    Write-Section "IMPLEMENTATION"

    $builderPrompt = @"
You are the primary implementation agent for Astra.

Read:
- .agent/TASK.md
- .agent/ROADMAP.md
- the repository architecture and existing tests

Implement exactly the requested task.

Rules:
- inspect existing code before editing
- do not broaden scope
- do not modify unrelated systems
- add focused tests
- require zero build warnings
- all existing tests must remain green
- do not write REVIEW.md
- do not modify ROADMAP.md
- do not create the next task
- do not commit yet

When finished, run:
dotnet build --no-incremental
dotnet test

Fix all failures before finishing.
"@

    Run-Claude $builderPrompt

    Check-Stop

    # ---------------------------------------------------------
    # 3. HARD VALIDATION
    # ---------------------------------------------------------

    if (!(Run-Validation)) {
        Write-Section "VALIDATION FAILED - CLAUDE FIX ROUND"

        $fixPrompt = @"
The Astra implementation does not currently pass validation.

Read:
- .agent/TASK.md
- current git diff

Run:
dotnet build --no-incremental
dotnet test

Fix only the failures caused by the current task.

Do not broaden scope.
Do not commit.

Finish only when build has zero warnings/errors and all tests pass.
"@

        Run-Claude $fixPrompt

        if (!(Run-Validation)) {
            throw "Validation failed again. Stopping supervisor."
        }
    }

    Check-Stop

    # ---------------------------------------------------------
    # 4. CODEX REVIEW
    # ---------------------------------------------------------

    Write-Section "CODE REVIEW"

    Remove-Item $ReviewFile -ErrorAction SilentlyContinue

    $reviewPrompt = @"
You are the senior reviewer for the Astra project.

Read:
- .agent/TASK.md
- .agent/ROADMAP.md
- git diff
- all code changed for this task
- relevant existing architecture

Review for:
- correctness
- architecture
- concurrency
- cancellation
- resource lifetime
- state/event semantics
- test quality
- regressions
- unnecessary complexity
- scope creep

Run:
dotnet build --no-incremental
dotnet test

Do NOT implement a new feature.

Small fixes to the current task are allowed if clearly necessary.
If you make fixes, rerun build and tests.

Then write exactly one of these to .agent/REVIEW.md:

STATUS: PASS

or:

STATUS: CHANGES_REQUIRED

followed by concise actionable findings.

Do not commit.
"@

    Run-Codex $reviewPrompt

    Check-Stop

    if (!(Test-Path $ReviewFile)) {
        throw "Codex did not create REVIEW.md"
    }

    $review = Get-Content $ReviewFile -Raw

    # ---------------------------------------------------------
    # 5. FIX REVIEW FINDINGS
    # ---------------------------------------------------------

    if ($review -match "STATUS:\s*CHANGES_REQUIRED") {

        Write-Section "REVIEW CHANGES REQUIRED"

        $reviewFixPrompt = @"
The reviewer requested changes.

Read:
- .agent/TASK.md
- .agent/REVIEW.md
- current git diff

Address every valid review finding.

Do not broaden scope.
Do not add unrelated features.
Do not commit.

Run:
dotnet build --no-incremental
dotnet test

Finish only when validation is green.
"@

        Run-Claude $reviewFixPrompt

        if (!(Run-Validation)) {
            throw "Post-review validation failed."
        }

        # Review once again.
        Remove-Item $ReviewFile -ErrorAction SilentlyContinue
        Run-Codex $reviewPrompt

        $review = Get-Content $ReviewFile -Raw

        if ($review -notmatch "STATUS:\s*PASS") {
            throw "Second review did not pass. Stopping for human inspection."
        }
    }

    Check-Stop

    # ---------------------------------------------------------
    # 6. FINAL VALIDATION + COMMIT
    # ---------------------------------------------------------

    if (!(Run-Validation)) {
        throw "Final validation failed."
    }

    Write-Section "COMMIT"

    git add src tests *.slnx

    # Don't commit supervisor control/output files.
    git reset -- .agent/TASK.md .agent/REVIEW.md 2>$null

    $status = git status --porcelain

    if ([string]::IsNullOrWhiteSpace($status)) {
        Write-Host "No source changes to commit."
    }
    else {
        $commitPrompt = @"
Read .agent/TASK.md and the current staged git diff.

Return ONLY one concise Conventional Commit message.

Examples:
feat: add safe point coordination
feat: add simulated guiding
fix: correct resource cancellation behavior

No explanation.
"@

        $commitMessage = (
            $commitPrompt | codex exec -
        ).Trim()

        git commit -m $commitMessage

        if ($LASTEXITCODE -ne 0) {
            throw "Git commit failed."
        }

        Write-Host "Committed:"
        git log -1 --oneline
    }

    # ---------------------------------------------------------
    # 7. CLEAN TASK STATE
    # ---------------------------------------------------------

    Remove-Item $TaskFile -ErrorAction SilentlyContinue
    Remove-Item $ReviewFile -ErrorAction SilentlyContinue

    Write-Section "SLICE COMPLETE - STARTING NEXT"
}