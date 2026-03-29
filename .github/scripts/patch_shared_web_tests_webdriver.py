#!/usr/bin/env python3

from pathlib import Path
import sys


HANDLER_PATH = Path("/workspace/tmp/shared-web-tests/webdriver/src/handler.rs")


GET_WINDOW_RECT_BLOCK = """            GetWindowRect => {
                let rect = serde_json::json!({
                    "x": 0,
                    "y": 0,
                    "width": 1280,
                    "height": 720
                });
                return Ok(WebDriverResponse::Generic(ValueResponse(rect)));
            },
"""


SET_WINDOW_RECT_BLOCK = """            SetWindowRect(_) => {
                let rect = serde_json::json!({
                    "x": 0,
                    "y": 0,
                    "width": 1280,
                    "height": 720
                });
                return Ok(WebDriverResponse::Generic(ValueResponse(rect)));
            },
"""


def main() -> int:
    if not HANDLER_PATH.exists():
        print(f"handler.rs not found at {HANDLER_PATH}", file=sys.stderr)
        return 1

    content = HANDLER_PATH.read_text()

    if "GetWindowRect =>" in content and "SetWindowRect(_) =>" in content:
        print("shared-web-tests webdriver already has window rect handlers")
        return 0

    get_anchor = """            GetWindowHandles => {
                let session_id = msg.session_id.as_ref().expect("Expected a session id");
                let window_handles = server_request_for_platform(session_id, &platform, "getWindowHandles", &std::collections::HashMap::new());
                // Parse json string
                let window_handles: Value = serde_json::from_str(&window_handles).expect("Failed to parse window handles");
                info!("Window handles: {:#?}", window_handles);
                return Ok(WebDriverResponse::Generic(ValueResponse(window_handles.into())));
            },
"""

    set_anchor = """            SwitchToWindow(params) => {
                let session_id = msg.session_id.as_ref().expect("Expected a session id");
                let mut params = std::collections::HashMap::new();
                params.insert("windowHandle", params.handle.as_str());
                server_request_for_platform(session_id, &platform, "switchToWindow", &params);
                return Ok(WebDriverResponse::Generic(ValueResponse(Value::Null)));
            },
"""

    updated = content

    if "GetWindowRect =>" not in updated:
        if get_anchor not in updated:
            print("Could not find GetWindowHandles anchor in handler.rs", file=sys.stderr)
            return 1
        updated = updated.replace(get_anchor, get_anchor + GET_WINDOW_RECT_BLOCK, 1)

    if "SetWindowRect(_) =>" not in updated:
        if set_anchor not in updated:
            print("Could not find SwitchToWindow anchor in handler.rs", file=sys.stderr)
            return 1
        updated = updated.replace(set_anchor, set_anchor + SET_WINDOW_RECT_BLOCK, 1)

    HANDLER_PATH.write_text(updated)
    print("Patched shared-web-tests webdriver window rect handlers for CI")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
