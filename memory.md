# Agent Memory Bank: _ct-BOOT

> Persistent knowledge, architecture, patterns, and decisions synced via `agent-memory-mcp`.

## 1. Project Overview & Architecture
- **Repository**: `_ct-BOOT`
- **Type**: Web / Digital Signage Application
- **Tech Stack**: HTML5, JavaScript, CSS3
- **Entry Points**: Root directory files
- **Description**: A self-contained, live-bootable Linux environment designed to turn any x86_64 PC or Mac into a full-screen HTML digital signage / kiosk display.

## 2. Core Operational Conventions & Protocol Rules
- **Response Constraints**: No conversational prose; use micro-diffs (`-` / `+`), standard git diffs, key-value pairs, or atomic bullet points.
- **Slideshow & Signage Navigation** (where applicable):
  - `ArrowLeft`: Previous slide (`prevSlide()`)
  - `ArrowRight`: Next slide (`nextSlide()`)
  - `ArrowUp`: Restart module from slide 0
  - `ArrowDown`: Skip to next module
  - `Space`: Toggle Pause / Unpause
  - `a` / `A`: Open Admin page in new tab (`admin.html` or `masteradmin.html`)
  - `r` / `R`: Open Remote page in new tab (`remote.html`)
  - `1`-`9`: Set slide display duration (10s to 90s) and restart active timer
  - `0`: Toggle Lock / Unlock freeze (progression freezes while animations continue)
  - Input Guard: Disable keyboard shortcuts when focus is in `input`, `textarea`, or `select` elements
- **UI/UX Requirements**:
  - **Clocks**: ALL CLOCKS MUST HAVE BLINKING COLONS (`:`).
  - **Resolution**: Optimised for 1080p viewing (1920x1080).
  - **Layout & Overflow**: Text must never overflow, clip screen edges, or ugly line wrap (`white-space: nowrap`, `text-overflow: ellipsis`, or scaled font size).

## 3. Key Decisions & Technical Patterns
- Modular component structure suited for automated display and signage loops.
- Local configuration sync and automated build verification.
- Fast, low-latency DOM updates and resilient error recovery.

## 4. Active Context & Operational State
- **Status**: Maintained
- **Last Sync**: 2026-09-11
- **Target Deployment**: Local Environment / Signage Display / Kiosk

## 5. Episodic Memory & Change Log
- **2026-09-11**: Initialized persistent `memory.md` bank across repository root.

## 6. Agent References
- [Agent Guidelines & Protocols](AGENTS.md)
