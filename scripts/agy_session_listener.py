#!/usr/bin/env python3
"""
Helper for any Antigravity agent session to attach to GoCoach.app via `.coach_ipc/`.

Commands:
  python3 scripts/agy_session_listener.py wait
      Maintains the agent heartbeat and blocks until GoCoach.app requests advice.
      Prints the compact tactical digest and exits 0 (triggering Antigravity's
      reactive background-task wakeup with zero polling tokens).

  python3 scripts/agy_session_listener.py reply <req_id> <advice_text>
      Delivers the coaching response back to GoCoach.app.
"""

import json
import pathlib
import sys
import time

WORKSPACE_DIR = pathlib.Path(__file__).resolve().parent.parent
IPC_DIR = WORKSPACE_DIR / ".coach_ipc"
REQUEST_FILE = IPC_DIR / "pending_request.json"
RESPONSE_FILE = IPC_DIR / "response.json"
HEARTBEAT_FILE = IPC_DIR / "agent_heartbeat.json"


def update_heartbeat() -> None:
    IPC_DIR.mkdir(parents=True, exist_ok=True)
    HEARTBEAT_FILE.write_text(
        json.dumps({"timestamp": time.time(), "status": "listening"}),
        encoding="utf-8",
    )


def wait_for_request() -> int:
    IPC_DIR.mkdir(parents=True, exist_ok=True)
    last_hb = 0.0
    while True:
        now = time.time()
        if now - last_hb >= 2.0:
            update_heartbeat()
            last_hb = now

        if REQUEST_FILE.exists():
            try:
                data = json.loads(REQUEST_FILE.read_text(encoding="utf-8"))
                # Ignore stale requests older than 30 seconds
                if now - float(data.get("created_at", now)) > 30.0:
                    REQUEST_FILE.unlink(missing_ok=True)
                else:
                    print(json.dumps(data, ensure_ascii=False, indent=2))
                    return 0
            except Exception:
                pass
        time.sleep(0.15)


def send_reply(req_id: str, text: str) -> int:
    IPC_DIR.mkdir(parents=True, exist_ok=True)
    update_heartbeat()
    payload = {
        "id": req_id,
        "text": text,
        "partial_text": text,
        "done": True,
        "timestamp": time.time(),
    }
    tmp = IPC_DIR / f"response_{req_id}.tmp"
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(RESPONSE_FILE)
    REQUEST_FILE.unlink(missing_ok=True)
    print(f"Delivered coaching response for request {req_id}")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    if cmd == "wait":
        return wait_for_request()
    if cmd == "reply" and len(sys.argv) >= 4:
        req_id = sys.argv[2]
        text = " ".join(sys.argv[3:])
        return send_reply(req_id, text)
    print(__doc__)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
