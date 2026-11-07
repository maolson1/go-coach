---
name: go-coach
description: Attach any Antigravity session as the live AI Go Coach for the native macOS GoCoach.app without needing an external API key.
---

# GoCoach Live Session Skill

This skill lets any Antigravity conversation act as the live coaching brain for `/Users/matt/go-coach/GoCoach.app` with near-zero idle token usage.

## Workflow

1. **Launch App (if requested)**:
   ```sh
   open /Users/matt/go-coach/GoCoach.app
   ```
2. **Wait for Blunder or "Ask Coach" Event**:
   Run `python3 /Users/matt/go-coach/scripts/agy_session_listener.py wait` with `WaitMsBeforeAsync: 500`. Stop calling tools and let Antigravity wake you up when a coaching request arrives.
3. **Deliver Concise Go Advice**:
   Read the ~200-token KataGo tactical digest output by the listener, craft a 2–3 sentence explanation focused on shape, liberties, direction of play, or life & death (without listing long coordinate sequences, since the board UI renders clickable variation branches), and send it via:
   ```sh
   python3 /Users/matt/go-coach/scripts/agy_session_listener.py reply "<request_id>" "<advice>"
   ```
4. **Re-arm Listener**:
   Immediately start `python3 /Users/matt/go-coach/scripts/agy_session_listener.py wait` (`WaitMsBeforeAsync: 500`) again so the next move is covered.
