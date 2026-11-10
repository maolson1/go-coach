# GoCoach — Native macOS Go Trainer with KataGo & Antigravity Coaching

**GoCoach** is a native macOS SwiftUI Go (Weiqi / Baduk) training app powered by **KataGo** (with its Human SL policy network) and **Antigravity** for concise, human-friendly Go coaching.

Instead of feeding full board transcripts to an LLM on every move, GoCoach runs KataGo locally on Apple Silicon Metal and only invokes the AI coach when a move loses significant value or when you click **Ask Coach**. When triggered, GoCoach synthesizes a compact (~200-token) tactical digest—complete with verified Principal Variation outcomes, human-likely opponent replies and their refutations, liberty counts, and shape tags—so the coach gives accurate, grounded Go advice with minimal token usage.

---

## Features

- **Human-Like Opponent at Any Rank (25k – 9d)**: Uses KataGo's `b18c384nbt-humanv0` Human SL model calibrated to your rank (`rank_20k` through `rank_9d`), with adaptive rank calibration after each game.
- **Interactive Variation Explorer**: Click directly on the **Best Move (`A`)**, **2nd Alternative (`B`)**, or **Opponent Punishment** variations in the sidebar to step through the numbered sequence directly on the board.
- **Human Reply & Refutation Analysis**: Queries both superhuman KataGo PVs and the most likely human reply (`humanPolicy`) so coaching advice explains how to refute natural human responses (such as ladders, wedges, and double threats) even when superhuman play would tenuki.
- **Counterfactual "What-If" Verification**: Ask follow-up questions containing coordinates (e.g., *"What if I played D10 instead?"*) and GoCoach automatically queries KataGo on that counterfactual move before answering.
- **3-Tier Coaching Pipeline**:
  1. **Live Antigravity Workspace Session (`.coach_ipc/`)**: Attach any active Antigravity conversation open in this repository as your live AI coach—no external API keys required.
  2. **`google-antigravity` Python SDK**: Programmatic coaching via `GEMINI_API_KEY`, Vertex AI (`GOOGLE_CLOUD_PROJECT` + `GOOGLE_CLOUD_LOCATION`), or a local OpenAI-compatible endpoint (`GOCOACH_OPENAI_BASE_URL`).
  3. **Offline KataGo Tactical Coach**: Instant deterministic coaching fallback when playing completely offline.

---

## Prerequisites

- **macOS 14.0 (Sonoma) or later** on Apple Silicon (`arm64`)
- **Xcode Command Line Tools** (`xcode-select --install`)
- **KataGo** and **Python 3** via [Homebrew](https://brew.sh):
  ```sh
  brew install katago python
  ```

---

## Quick Start (Build & Launch)

Clone the repository and run the bundle script:

```sh
git clone <your-repo-url> go-coach
cd go-coach
./scripts/bundle_app.sh
open GoCoach.app
```

What `./scripts/bundle_app.sh` does automatically on first run:
1. Creates a Python virtual environment in `.venv/` and installs [`requirements.txt`](requirements.txt) (`google-antigravity`).
2. Downloads the KataGo Human SL neural network (`b18c384nbt-humanv0.bin.gz`, ~72 MB) from the official KataGo release into `Resources/models/`.
3. Compiles the SwiftUI app with `swiftc -O` and packages `GoCoach.app`.

### Manual Virtualenv Setup (Optional)

If you want to create or recreate the Python virtual environment manually:

```sh
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt
```

---

## Connecting Antigravity as Your Live Coach

### Option A: Live Antigravity IDE / CLI Session (No API Key Required)

1. Open this `go-coach` folder as your workspace in **Antigravity**.
2. Ask the agent in chat:
   > *"Start GoCoach and coach me."*
3. Guided by [`GEMINI.md`](GEMINI.md) and [`.agents/skills/go-coach/SKILL.md`](.agents/skills/go-coach/SKILL.md), the agent will launch `GoCoach.app` and run:
   ```sh
   python3 scripts/agy_session_listener.py wait
   ```
   in the background using Antigravity's reactive task wakeup (consuming zero tokens while you play normal moves).
4. Whenever you play a blunder or click **Ask Coach**, the listener wakes the agent with the compact KataGo tactical digest, delivers a 2–3 sentence explanation back to `GoCoach.app`, and re-arms automatically for your next move.

### Option B: Standalone via `google-antigravity` SDK or Local LLM

If you launch `GoCoach.app` without an active Antigravity chat listener, `scripts/coach_bridge.py` checks for SDK credentials in your environment:

- **Gemini API**:
  ```sh
  export GEMINI_API_KEY="your-api-key"
  open GoCoach.app
  ```
- **Google Cloud Vertex AI**:
  ```sh
  export GOOGLE_CLOUD_PROJECT="your-project-id"
  export GOOGLE_CLOUD_LOCATION="us-central1"
  open GoCoach.app
  ```
- **Local OpenAI-Compatible Server (e.g., Ollama / LM Studio)**:
  ```sh
  export GOCOACH_OPENAI_BASE_URL="http://localhost:11434/v1"
  export GOCOACH_OPENAI_MODEL="gemma3"
  open GoCoach.app
  ```

---

## Project Structure

```text
go-coach/
├── GEMINI.md                        # Workspace rule for live Antigravity coaching
├── .agents/skills/go-coach/SKILL.md # Antigravity skill definition
├── Package.swift                    # Swift Package manifest
├── requirements.txt                 # Python dependencies (.venv)
├── Resources/
│   ├── AppIcon.icns                 # macOS app icon
│   └── models/                      # KataGo Human SL model (downloaded by bundle_app.sh)
├── Sources/GoCoach/
│   ├── GoCoachApp.swift             # App entry point & menu commands
│   ├── Models/
│   │   ├── BoardState.swift         # Go rules, liberty/shape analysis & tactical digest builder
│   │   ├── GameSession.swift        # Game loop, KataGo orchestration & PV exploration
│   │   └── PlayerRating.swift       # Persistent kyu/dan rank & post-game auto-calibration
│   ├── Services/
│   │   ├── KataGoService.swift      # Persistent KataGo analysis engine subprocess
│   │   ├── CoachBridgeService.swift # JSON-Lines IPC bridge to coach_bridge.py
│   │   └── SoundManager.swift       # Synthesized stone click & capture audio
│   └── Views/
│       ├── MainWindowView.swift     # Split-view window layout & toolbar
│       ├── GobanView.swift          # Interactive Kaya wood board, heatmaps & PV stones
│       ├── CoachSidebarView.swift   # Coaching chat, blunder cards & PV branch toggles
│       └── NewGameSheet.swift       # Board size (9x9, 13x13, 19x19), handicap & rank setup
└── scripts/
    ├── bundle_app.sh                # One-step setup & macOS .app bundler
    ├── coach_bridge.py              # 3-tier Antigravity / SDK / offline coaching bridge
    ├── agy_session_listener.py      # Reactive IPC listener for live Antigravity sessions
    └── generate_icon.swift          # Procedural macOS AppIcon generator
```

---

## License

Released under the [MIT License](LICENSE).
