# GoCoach Workspace Rules (`GEMINI.md`)

- **Do not automatically launch or restart `GoCoach.app`** after making changes or building—the user will launch the app themselves.

When the user asks you to coach them, start GoCoach, or attach to a game in this workspace:

1. Start the reactive coaching listener in the background using `run_command` with `WaitMsBeforeAsync: 500`:
   ```sh
   python3 scripts/agy_session_listener.py wait
   ```
   Do **not** poll the task—end your turn and wait for Antigravity's reactive background-task wakeup when the player makes a blunder or clicks **Ask Coach** in `GoCoach.app`.
2. When the listener task completes and outputs a JSON request (`id`, `digest`, `question`), respond to the app by running:
   ```sh
   python3 scripts/agy_session_listener.py reply "<id>" "<your 2-3 sentence human-friendly Go coaching explanation>"
   ```
   and immediately re-arm `python3 scripts/agy_session_listener.py wait` (`WaitMsBeforeAsync: 500`) for the next move.
