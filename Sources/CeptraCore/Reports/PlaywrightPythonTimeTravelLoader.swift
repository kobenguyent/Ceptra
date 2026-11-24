import Foundation

/// Generates and caches a zero-dependency Python stdlib pytest plugin (`-p ceptra_pw_time_travel`
/// via `PYTHONPATH`) that captures every `pytest-playwright` test, pytest markers/tags,
/// duration, stdout/stderr, error stack, and full Playwright `trace.zip` telemetry
/// (step-by-step actions, before/after screencast JPEGs, DOM snapshots, target bounding boxes,
/// browser console/pageerrors, browser network, and `APIRequestContext` HTTP exchanges)
/// into Ceptra's native `TimeTravelTraceBundle` JSON schema — with zero edits to the
/// user's `pytest.ini`, `pyproject.toml`, or `conftest.py`.
public enum PlaywrightPythonTimeTravelLoader {
    private static let directoryName = "ceptra-pw-py-time-travel-v1"
    public static let pluginModuleName = "ceptra_pw_time_travel"
    private static let pluginFileName = "ceptra_pw_time_travel.py"

    public static let pluginScriptSource: String = #"""
    """Zero-dependency Ceptra Time-Travel pytest plugin for Playwright Python (pytest-playwright)."""
    import base64
    import datetime
    import json
    import os
    import re
    import time
    import urllib.parse
    import uuid
    import zipfile
    from pathlib import Path

    MAX_ATTACHMENT_BYTES = 1536 * 1024
    MAX_ZIP_BYTES = 64 * 1024 * 1024
    MAX_ERROR_CHARS = 8192
    MAX_CONSOLE_CHARS = 4096
    MAX_DOM_CHARS = 160 * 1024
    MAX_API_BODY_CHARS = 128 * 1024
    MAX_BROWSER_BODY_CHARS = 32 * 1024
    MAX_BROWSER_NET_PER_STEP = 40

    ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
    SENSITIVE_HEADER_RE = re.compile(
        r"^(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key|"
        r"x-auth-token|x-access-token|x-csrf-token|x-xsrf-token)$",
        re.IGNORECASE,
    )
    VOID_HTML_TAGS = {
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    }
    INTERNAL_API_NAMES = {
        "browserType.launch", "browser.newContext", "browserContext.newPage",
        "browserContext.close", "browserContext.tracingStart", "browserContext.tracingStop",
        "browserContext.tracingStartChunk", "browserContext.tracingStopChunk",
        "page.close", "apiRequest.newContext", "apiRequestContext.dispose",
        "tracing.start", "tracing.stop", "tracing.startChunk", "tracing.stopChunk",
        "tracing.tracingStart", "tracing.tracingStop",
        "tracing.tracingStartChunk", "tracing.tracingStopChunk",
    }
    LOCATOR_FRAME_METHODS = {
        "click", "dblclick", "fill", "type", "press", "hover", "check", "uncheck",
        "selectOption", "tap", "focus", "blur", "setInputFiles", "dispatchEvent",
        "scrollIntoViewIfNeeded", "waitForSelector", "inputValue", "textContent",
        "innerText", "innerHTML", "getAttribute", "isVisible", "isHidden",
        "isEnabled", "isDisabled", "isChecked", "isEditable",
    }
    WEB_ASSERTION_PATTERNS = (
        "tobevisible", "to_be_visible", "tobehidden", "to_be_hidden",
        "tobeenabled", "to_be_enabled", "tobedisabled", "to_be_disabled",
        "tobechecked", "to_be_checked", "tobefocused", "to_be_focused",
        "tobeattached", "to_be_attached", "tobeeditable", "to_be_editable",
        "tobeempty", "to_be_empty", "tobeinviewport", "to_be_in_viewport",
        "tohavetext", "to_have_text", "tocontaintext", "to_contain_text",
        "tohavevalue", "to_have_value", "tohavevalues", "to_have_values",
        "tohaveattribute", "to_have_attribute", "tohaveclass", "to_have_class",
        "tohavecount", "to_have_count", "tohavecss", "to_have_css",
        "tohaveid", "to_have_id", "tohaveurl", "to_have_url",
        "tohavetitle", "to_have_title", "tohavescreenshot", "to_have_screenshot",
    )

    _ACTIVE_PLUGIN = None
    _HOOKS_INSTALLED = False


    def _strip_ansi(text):
        if not isinstance(text, str):
            return ""
        return ANSI_RE.sub("", text)


    def _truncate(text, limit):
        if not isinstance(text, str):
            return None
        if len(text) <= limit:
            return text
        return text[:limit] + "\n# [truncated by Ceptra]"


    def _iso_from_ms(epoch_ms):
        if epoch_ms is None:
            dt = datetime.datetime.now(datetime.timezone.utc)
        else:
            dt = datetime.datetime.fromtimestamp(epoch_ms / 1000.0, tz=datetime.timezone.utc)
        return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


    def _parse_iso_ms(val):
        if not isinstance(val, str) or not val:
            return None
        try:
            clean = val.replace("Z", "+00:00")
            dt = datetime.datetime.fromisoformat(clean)
            return int(dt.timestamp() * 1000.0)
        except Exception:
            return None


    def _empty_diagnostics():
        return {
            "pageURL": None,
            "beforeScreenshotDataURI": None,
            "afterScreenshotDataURI": None,
            "domSnapshot": None,
            "networkRequests": [],
            "consoleEntries": [],
            "assertion": None,
        }


    def _escape_html_attr(val):
        return (
            str(val)
            .replace("&", "&amp;")
            .replace('"', "&quot;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
        )


    def _escape_html_text(val):
        return str(val).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


    def _build_snapshot_nodes(raw_html):
        """Post-order node list matching Playwright's SnapshotRenderer (strings + elements, skipping subtree refs)."""
        nodes = []

        def _visit(n):
            if isinstance(n, str):
                nodes.append(n)
            elif isinstance(n, list) and n and isinstance(n[0], str):
                start_i = 2 if len(n) > 1 and isinstance(n[1], dict) else 1
                for ch in n[start_i:]:
                    _visit(ch)
                nodes.append(n)

        _visit(raw_html)
        return nodes


    def _is_subtree_ref(node):
        return (
            isinstance(node, list)
            and len(node) == 1
            and isinstance(node[0], list)
            and len(node[0]) >= 2
            and isinstance(node[0][0], int)
            and isinstance(node[0][1], int)
        )


    def _serialize_pw_dom_node(node, budget, depth=0, snap_idx=None, frame_snaps=None, target_call_id=None, target_capture=None):
        if node is None or budget[0] >= MAX_DOM_CHARS or depth > 64:
            return ""
        if isinstance(node, str):
            esc = _escape_html_text(node)
            budget[0] += len(esc)
            return esc
        if not isinstance(node, list) or not node:
            return ""
        if _is_subtree_ref(node):
            if snap_idx is not None and frame_snaps:
                ref_offset, node_idx = node[0][0], node[0][1]
                ref_snap_idx = snap_idx - ref_offset
                if 0 <= ref_snap_idx < len(frame_snaps):
                    ref_snap = frame_snaps[ref_snap_idx]
                    ref_nodes = ref_snap.get("_nodes")
                    if ref_nodes is None:
                        ref_nodes = _build_snapshot_nodes(ref_snap.get("htmlNode"))
                        ref_snap["_nodes"] = ref_nodes
                    if 0 <= node_idx < len(ref_nodes):
                        return _serialize_pw_dom_node(
                            ref_nodes[node_idx],
                            budget,
                            depth + 1,
                            ref_snap_idx,
                            frame_snaps,
                            target_call_id,
                            target_capture,
                        )
            return ""
        if not isinstance(node[0], str):
            return ""

        tag = node[0].lower()
        if tag in ("script", "noscript"):
            return ""

        attrs = node[1] if len(node) > 1 and isinstance(node[1], dict) else None
        is_target = False
        attr_str = ""
        if attrs:
            if target_call_id and attrs.get("__playwright_target__") == target_call_id:
                is_target = True
            for k, v in attrs.items():
                if str(k).startswith("__playwright_"):
                    continue
                if v == "" or v is True:
                    attr_str += f" {k}"
                elif v is not None and v is not False:
                    attr_str += f' {k}="{_escape_html_attr(v)}"'

        if tag in VOID_HTML_TAGS:
            out = f"<{tag}{attr_str}>"
            budget[0] += len(out)
            if is_target and target_capture is not None and target_capture[0] is None:
                target_capture[0] = _truncate(out, 2048)
            return out

        open_tag = f"<{tag}{attr_str}>"
        budget[0] += len(open_tag)
        start_idx = 2 if attrs is not None else 1
        inner_parts = []
        for child in node[start_idx:]:
            if budget[0] >= MAX_DOM_CHARS:
                break
            inner_parts.append(
                _serialize_pw_dom_node(
                    child,
                    budget,
                    depth + 1,
                    snap_idx,
                    frame_snaps,
                    target_call_id,
                    target_capture,
                )
            )
        close_tag = f"</{tag}>"
        budget[0] += len(close_tag)
        full = open_tag + "".join(inner_parts) + close_tag
        if is_target and target_capture is not None and target_capture[0] is None:
            target_capture[0] = _truncate(full, 2048)
        return full


    def _extract_title_from_html(html):
        if not html:
            return None
        m = re.search(r"<title[^>]*>([^<]{1,200})</title>", html, re.IGNORECASE)
        return m.group(1).strip() if m else None


    def _redact_headers(headers_arr):
        out = {}
        if isinstance(headers_arr, dict):
            for name, val in headers_arr.items():
                key = str(name or "")
                if not key or key.startswith(":"):
                    continue
                out[key] = "[REDACTED]" if SENSITIVE_HEADER_RE.match(key) else str(val or "")
            return out
        if not isinstance(headers_arr, list):
            return out
        for h in headers_arr:
            if not isinstance(h, dict):
                continue
            name = str(h.get("name") or "")
            if not name or name.startswith(":"):
                continue
            out[name] = "[REDACTED]" if SENSITIVE_HEADER_RE.match(name) else str(h.get("value") or "")
        return out


    def _clean_selector_display(selector):
        if not isinstance(selector, str):
            return ""
        s = selector.strip()
        if s.startswith("internal:"):
            s = s[len("internal:"):]
        return s


    def _synthesize_api_name(ev):
        raw = str(ev.get("apiName") or "").strip()
        if raw:
            return raw
        cls = str(ev.get("class") or "").strip()
        method = str(ev.get("method") or "").strip()
        params = ev.get("params") if isinstance(ev.get("params"), dict) else {}
        if method == "expect":
            expr = str(params.get("expression") or "").strip()
            if expr:
                return f"expect.{expr.replace('.', '_')}"
            return "expect"
        if cls == "Frame":
            if method in LOCATOR_FRAME_METHODS and isinstance(params.get("selector"), str):
                return f"locator.{method}"
            return f"page.{method}" if method else "page"
        if cls:
            cls_camel = cls[0].lower() + cls[1:]
            return f"{cls_camel}.{method}" if method else cls_camel
        return method


    def _extract_expected_text(params):
        if not isinstance(params, dict):
            return None
        exp_text = params.get("expectedText")
        if isinstance(exp_text, list) and exp_text:
            parts = []
            for item in exp_text:
                if isinstance(item, dict):
                    if item.get("regexSource"):
                        flags = item.get("regexFlags") or ""
                        parts.append(f"/{item['regexSource']}/{flags}")
                    elif item.get("string") is not None:
                        parts.append(str(item["string"]))
            if parts:
                return ", ".join(parts)
        if params.get("expectedValue") is not None:
            try:
                return json.dumps(params["expectedValue"]) if isinstance(params["expectedValue"], (dict, list)) else str(params["expectedValue"])
            except Exception:
                return str(params["expectedValue"])
        if params.get("expectedNumber") is not None:
            return str(params["expectedNumber"])
        return None


    def _format_pw_received_value(raw):
        """Unwrap Playwright's wire protocol `received` payload (e.g. `{'value': {'s': '...'}, 'ariaSnapshot': ...}`)."""
        def _unwrap(v):
            if isinstance(v, dict):
                if "value" in v:
                    return _unwrap(v["value"])
                if "s" in v and len(v) <= 2:
                    return str(v["s"])
                if "n" in v and len(v) <= 2:
                    return str(v["n"])
                if "b" in v and len(v) <= 2:
                    return "true" if v["b"] else "false"
                if "v" in v and len(v) <= 2:
                    return str(v["v"])
                if "a" in v and isinstance(v["a"], list):
                    return ", ".join(_unwrap(x) for x in v["a"])
                if "o" in v and isinstance(v["o"], list):
                    pairs = [f"{item.get('k')}: {_unwrap(item.get('v'))}" for item in v["o"] if isinstance(item, dict)]
                    return "{" + ", ".join(pairs) + "}"
            if isinstance(v, list):
                return ", ".join(_unwrap(x) for x in v)
            return str(v) if v is not None else None

        val = _unwrap(raw)
        return _truncate(val, 512) if val is not None else None


    def _guess_resource_type(mime_type, url):
        mime = str(mime_type or "").lower()
        if "json" in mime or "graphql" in mime:
            return "fetch"
        if "html" in mime:
            return "document"
        if "javascript" in mime:
            return "script"
        if "css" in mime:
            return "stylesheet"
        if mime.startswith("image/"):
            return "image"
        if mime.startswith("font/"):
            return "font"
        u = str(url or "").lower()
        if re.search(r"\.(?:js|mjs)(?:[?#]|$)", u):
            return "script"
        if re.search(r"\.css(?:[?#]|$)", u):
            return "stylesheet"
        return "other"


    def _is_text_mime(mime_type):
        m = str(mime_type or "").lower()
        return any(tok in m for tok in ("json", "xml", "text/", "javascript", "graphql", "form-urlencoded"))


    def _round_pos_ms(val):
        if isinstance(val, (int, float)) and val > 0:
            return int(round(val))
        return None


    def _is_web_assertion(method):
        lower = str(method or "").lower()
        return any(p in lower for p in WEB_ASSERTION_PATTERNS)


    def _format_action_step_text(act):
        title = str(act.get("title") or "").strip()
        api_name = str(act.get("apiName") or "").strip()
        params = act.get("params") or {}
        if title:
            sel = _clean_selector_display(params.get("selector"))
            exp = _extract_expected_text(params)
            if sel and sel not in title:
                return f"{title} ({sel})"
            if exp and exp not in title:
                return f"{title} ({exp})"
            return title
        if api_name:
            if "goto" in api_name and isinstance(params.get("url"), str):
                return f'page.goto("{params["url"]}")'
            if isinstance(params.get("selector"), str):
                sel = _clean_selector_display(params["selector"])
                return f'{api_name}("{sel}")'
            if isinstance(params.get("url"), str):
                method = str(params.get("method") or "").upper()
                if method:
                    return f'{method} {params["url"]}'
                return f'{api_name}("{params["url"]}")'
            return api_name
        return "Playwright step"


    def parse_playwright_trace_zip(zip_path):
        """Parse a Playwright trace.zip archive using pure stdlib zipfile."""
        try:
            st = os.stat(zip_path)
            if st.st_size < 22 or st.st_size > MAX_ZIP_BYTES:
                return None
        except OSError:
            return None

        viewport = None
        base_url = None
        screencast_frames = []
        actions_by_call = {}
        action_order = []
        input_boxes = {}
        frame_snapshots = []
        frame_snaps_by_frame = {}
        console_events = []
        network_entries = []

        try:
            zf = zipfile.ZipFile(zip_path, "r")
        except Exception:
            return None

        with zf:
            names = zf.namelist()
            name_set = set(names)

            def read_bytes(name):
                if name not in name_set:
                    return None
                try:
                    return zf.read(name)
                except Exception:
                    return None

            def read_text(name):
                b = read_bytes(name)
                if b is None:
                    return None
                try:
                    return b.decode("utf-8", errors="replace")
                except Exception:
                    return None

            # 1. Parse all *.trace NDJSON files
            for fname in names:
                if not fname.endswith(".trace") or fname.endswith(".stacks"):
                    continue
                content = read_text(fname)
                if not content:
                    continue
                base_wall = None
                base_mono = None

                def to_wall_ms(ev):
                    fswap = ev.get("frameSwapWallTime")
                    if isinstance(fswap, (int, float)) and fswap > 1e12:
                        return float(fswap)
                    wt = ev.get("wallTime")
                    if isinstance(wt, (int, float)) and wt > 1e12:
                        return float(wt)
                    mono = ev.get("timestamp")
                    if not isinstance(mono, (int, float)):
                        mono = ev.get("startTime")
                    if not isinstance(mono, (int, float)):
                        mono = ev.get("time")
                    if isinstance(mono, (int, float)) and base_wall is not None and base_mono is not None:
                        return base_wall + (mono - base_mono)
                    return None

                for raw_line in content.splitlines():
                    if not raw_line or not raw_line.startswith("{"):
                        continue
                    try:
                        ev = json.loads(raw_line)
                    except Exception:
                        continue
                    etype = ev.get("type")
                    if not etype:
                        continue

                    if etype == "context-options":
                        if isinstance(ev.get("wallTime"), (int, float)):
                            base_wall = float(ev["wallTime"])
                        if isinstance(ev.get("monotonicTime"), (int, float)):
                            base_mono = float(ev["monotonicTime"])
                        opts = ev.get("options") or {}
                        if base_url is None and isinstance(opts.get("baseURL"), str) and opts["baseURL"]:
                            base_url = opts["baseURL"]
                        vp = opts.get("viewport")
                        if viewport is None and isinstance(vp, dict):
                            viewport = {
                                "width": float(vp.get("width") or 1280),
                                "height": float(vp.get("height") or 720),
                            }
                    elif etype == "screencast-frame":
                        fref = ev.get("file") or (f"resources/{ev['sha1']}" if ev.get("sha1") else None)
                        if fref:
                            if viewport is None and ev.get("width") and ev.get("height"):
                                viewport = {
                                    "width": float(ev["width"]),
                                    "height": float(ev["height"]),
                                }
                            screencast_frames.append({
                                "file": fref,
                                "width": float(ev.get("width") or (viewport["width"] if viewport else 1280)),
                                "height": float(ev.get("height") or (viewport["height"] if viewport else 720)),
                                "wallTime": to_wall_ms(ev),
                                "mono": float(ev.get("timestamp") or 0),
                            })
                    elif etype == "before" and ev.get("callId"):
                        cid = str(ev["callId"])
                        w = to_wall_ms(ev)
                        api_name = _synthesize_api_name(ev)
                        act = {
                            "callId": cid,
                            "apiName": api_name,
                            "title": str(ev.get("title") or ""),
                            "method": str(ev.get("method") or ""),
                            "params": ev.get("params") if isinstance(ev.get("params"), dict) else {},
                            "beforeSnapshot": ev.get("beforeSnapshot"),
                            "inputSnapshot": None,
                            "afterSnapshot": None,
                            "startWallMs": w,
                            "endWallMs": w,
                            "startMono": ev.get("startTime") if isinstance(ev.get("startTime"), (int, float)) else None,
                            "error": None,
                            "actualResult": None,
                        }
                        if cid not in actions_by_call:
                            action_order.append(cid)
                        actions_by_call[cid] = act
                    elif etype == "after" and ev.get("callId"):
                        cid = str(ev["callId"])
                        act = actions_by_call.get(cid)
                        if act:
                            end_mono = ev.get("endTime")
                            if isinstance(end_mono, (int, float)) and act["startMono"] is not None and act["startWallMs"] is not None:
                                act["endWallMs"] = act["startWallMs"] + max(0.0, float(end_mono) - float(act["startMono"]))
                            if ev.get("afterSnapshot"):
                                act["afterSnapshot"] = ev.get("afterSnapshot")
                            if isinstance(ev.get("result"), dict) and "received" in ev["result"]:
                                act["actualResult"] = _format_pw_received_value(ev["result"]["received"])
                            if ev.get("point") and cid not in input_boxes:
                                pt = ev["point"]
                                if isinstance(pt, dict) and isinstance(pt.get("x"), (int, float)):
                                    input_boxes[cid] = {
                                        "x": max(0.0, float(pt["x"]) - 16.0),
                                        "y": max(0.0, float(pt.get("y") or 0) - 16.0),
                                        "width": 32.0,
                                        "height": 32.0,
                                    }
                            if ev.get("error"):
                                err = ev["error"]
                                msg = err.get("message") if isinstance(err, dict) else str(err)
                                act["error"] = _truncate(_strip_ansi(str(msg or "")), MAX_ERROR_CHARS)
                    elif etype == "input" and ev.get("callId"):
                        cid = str(ev["callId"])
                        if cid in actions_by_call and ev.get("inputSnapshot"):
                            actions_by_call[cid]["inputSnapshot"] = ev.get("inputSnapshot")
                        box = ev.get("box")
                        pt = ev.get("point")
                        if isinstance(box, dict) and isinstance(box.get("x"), (int, float)):
                            input_boxes[cid] = {
                                "x": float(box["x"]),
                                "y": float(box.get("y") or 0),
                                "width": float(box.get("width") or 24),
                                "height": float(box.get("height") or 24),
                            }
                        elif isinstance(pt, dict) and isinstance(pt.get("x"), (int, float)):
                            input_boxes[cid] = {
                                "x": max(0.0, float(pt["x"]) - 16.0),
                                "y": max(0.0, float(pt.get("y") or 0) - 16.0),
                                "width": 32.0,
                                "height": 32.0,
                            }
                    elif etype == "frame-snapshot" and isinstance(ev.get("snapshot"), dict):
                        snap = ev["snapshot"]
                        if snap.get("isMainFrame") is False:
                            continue
                        ts = snap.get("timestamp")
                        if isinstance(ts, (int, float)) and base_wall is not None and base_mono is not None:
                            swall = base_wall + (float(ts) - base_mono)
                        else:
                            swall = to_wall_ms(ev)
                        sname = str(snap.get("snapshotName") or "")
                        snap_call_id = snap.get("callId")
                        phase = "after"
                        if sname.startswith("before"):
                            phase = "before"
                        elif sname.startswith("input"):
                            phase = "input"
                        if not snap_call_id and "@" in sname:
                            prefix, rest = sname.split("@", 1)
                            if prefix in ("before", "after", "input"):
                                snap_call_id = rest
                        fid = str(snap.get("frameId") or "__main__")
                        flist = frame_snaps_by_frame.setdefault(fid, [])
                        f_idx = len(flist)
                        entry = {
                            "snapshotName": sname,
                            "callId": snap_call_id,
                            "phase": phase,
                            "frameId": fid,
                            "frameIndex": f_idx,
                            "frameUrl": snap.get("frameUrl"),
                            "viewport": snap.get("viewport") or viewport,
                            "wallTime": swall,
                            "htmlNode": snap.get("html"),
                        }
                        flist.append(entry)
                        frame_snapshots.append(entry)
                    elif etype == "console":
                        w = to_wall_ms(ev)
                        lvl = str(ev.get("messageType") or "log").lower()
                        mapped = "warn" if lvl == "warning" else (lvl if lvl in ("log", "info", "warn", "error", "debug") else "log")
                        loc = ev.get("location") if isinstance(ev.get("location"), dict) else {}
                        console_events.append({
                            "wallTime": w,
                            "entry": {
                                "id": str(uuid.uuid4()),
                                "level": mapped,
                                "message": _truncate(_strip_ansi(str(ev.get("text") or "")), MAX_CONSOLE_CHARS) or "",
                                "timestamp": _iso_from_ms(w),
                                "sourceURL": str(loc["url"]) if loc.get("url") else None,
                                "lineNumber": int(loc["lineNumber"]) if isinstance(loc.get("lineNumber"), int) else None,
                            },
                        })
                    elif etype == "event" and ev.get("method") == "pageError":
                        w = to_wall_ms(ev)
                        params = ev.get("params") or {}
                        err_obj = params.get("error") or {}
                        if isinstance(err_obj, dict) and isinstance(err_obj.get("error"), dict):
                            err_obj = err_obj["error"]
                        msg = (err_obj.get("stack") or err_obj.get("message")) if isinstance(err_obj, dict) else str(err_obj)
                        console_events.append({
                            "wallTime": w,
                            "entry": {
                                "id": str(uuid.uuid4()),
                                "level": "pageerror",
                                "message": _truncate(_strip_ansi(str(msg or "Uncaught page error")), MAX_CONSOLE_CHARS) or "Uncaught page error",
                                "timestamp": _iso_from_ms(w),
                                "sourceURL": None,
                                "lineNumber": None,
                            },
                        })

            # 2. Parse all *.network NDJSON files
            for fname in names:
                if not fname.endswith(".network"):
                    continue
                content = read_text(fname)
                if not content:
                    continue
                for raw_line in content.splitlines():
                    if not raw_line or not raw_line.startswith("{"):
                        continue
                    try:
                        ev = json.loads(raw_line)
                    except Exception:
                        continue
                    if ev.get("type") != "resource-snapshot" or not isinstance(ev.get("snapshot"), dict):
                        continue
                    snap = ev["snapshot"]
                    req = snap.get("request") or {}
                    res = snap.get("response") or {}
                    is_api = bool(snap.get("_apiRequestRef"))
                    url = str(req.get("url") or "")
                    if not url or url.startswith("data:"):
                        continue

                    started_ms = _parse_iso_ms(snap.get("startedDateTime"))
                    total_ms = _round_pos_ms(snap.get("time")) if snap.get("time") is not None else None
                    if total_ms is None and isinstance(snap.get("time"), (int, float)) and snap["time"] >= 0:
                        total_ms = 0

                    req_body = None
                    post_data = req.get("postData")
                    if isinstance(post_data, dict):
                        if isinstance(post_data.get("text"), str) and post_data["text"]:
                            req_body = _truncate(post_data["text"], MAX_API_BODY_CHARS if is_api else MAX_BROWSER_BODY_CHARS)
                        elif post_data.get("_sha1"):
                            raw_b = read_text(f"resources/{post_data['_sha1']}")
                            if raw_b:
                                req_body = _truncate(raw_b, MAX_API_BODY_CHARS if is_api else MAX_BROWSER_BODY_CHARS)

                    res_body = None
                    res_content = res.get("content") if isinstance(res.get("content"), dict) else {}
                    mime_type = str(res_content.get("mimeType") or "")
                    res_key = str(res_content["_file"]) if res_content.get("_file") else (
                        f"resources/{res_content['_sha1']}" if res_content.get("_sha1") else None
                    )
                    if isinstance(res_content.get("text"), str) and res_content["text"]:
                        if is_api or _is_text_mime(mime_type):
                            txt = res_content["text"]
                            if res_content.get("encoding") == "base64":
                                try:
                                    txt = base64.b64decode(txt).decode("utf-8", errors="replace")
                                except Exception:
                                    pass
                            res_body = _truncate(txt, MAX_API_BODY_CHARS if is_api else MAX_BROWSER_BODY_CHARS)
                    elif res_key and (is_api or _is_text_mime(mime_type)):
                        raw_b = read_text(res_key)
                        if raw_b:
                            res_body = _truncate(raw_b, MAX_API_BODY_CHARS if is_api else MAX_BROWSER_BODY_CHARS)

                    t = snap.get("timings") if isinstance(snap.get("timings"), dict) else {}
                    dns_ms = _round_pos_ms(t.get("dns"))
                    conn_ms = _round_pos_ms(t.get("connect"))
                    tls_ms = _round_pos_ms(t.get("ssl"))
                    ttfb_ms = _round_pos_ms(t.get("wait"))
                    dl_ms = _round_pos_ms(t.get("receive"))
                    has_timings = any(x is not None for x in (dns_ms, conn_ms, tls_ms, ttfb_ms, dl_ms, total_ms))

                    status_num = res.get("status")
                    status_val = int(status_num) if isinstance(status_num, (int, float)) and status_num > 0 else None
                    fail_text = str(res["_failureText"]) if res.get("_failureText") else None

                    network_entries.append({
                        "startedAtMs": started_ms,
                        "isApi": is_api,
                        "entry": {
                            "id": str(uuid.uuid4()),
                            "method": str(req.get("method") or "GET").upper(),
                            "url": url,
                            "resourceType": "api" if is_api else _guess_resource_type(mime_type, url),
                            "source": "playwright-python-api" if is_api else "playwright-browser",
                            "status": status_val,
                            "statusText": str(res["statusText"]) if res.get("statusText") else None,
                            "startedAt": _iso_from_ms(started_ms) if started_ms is not None else None,
                            "durationMs": total_ms,
                            "requestSizeBytes": int(req["bodySize"]) if isinstance(req.get("bodySize"), (int, float)) and req["bodySize"] > 0 else (len(req_body.encode("utf-8")) if req_body else None),
                            "responseSizeBytes": int(res_content["size"]) if isinstance(res_content.get("size"), (int, float)) and res_content["size"] > 0 else (len(res_body.encode("utf-8")) if res_body else None),
                            "timings": {
                                "dnsMs": dns_ms,
                                "connectMs": conn_ms,
                                "tlsMs": tls_ms,
                                "ttfbMs": ttfb_ms,
                                "downloadMs": dl_ms,
                                "totalMs": total_ms,
                            } if has_timings else None,
                            "requestHeaders": _redact_headers(req.get("headers")),
                            "responseHeaders": _redact_headers(res.get("headers")),
                            "requestBody": req_body,
                            "responseBody": res_body,
                            "errorText": fail_text,
                        },
                    })

            # Cache frame data URIs & serialized DOM snapshots (resolving Playwright incremental delta refs)
            frame_uri_cache = {}
            for frame in screencast_frames:
                fref = frame["file"]
                if fref not in frame_uri_cache:
                    raw_img = read_bytes(fref)
                    if raw_img and 0 < len(raw_img) <= MAX_ATTACHMENT_BYTES:
                        ext = os.path.splitext(fref)[1].lower()
                        mime = "image/png" if ext == ".png" else ("image/webp" if ext == ".webp" else "image/jpeg")
                        frame_uri_cache[fref] = f"data:{mime};base64,{base64.b64encode(raw_img).decode('ascii')}"
                    else:
                        frame_uri_cache[fref] = None

            serialized_snaps = []
            for sn in frame_snapshots:
                flist = frame_snaps_by_frame.get(sn["frameId"], [])
                target_capture = [None]
                html_str = (
                    _serialize_pw_dom_node(
                        sn["htmlNode"],
                        [0],
                        0,
                        sn["frameIndex"],
                        flist,
                        sn["callId"],
                        target_capture,
                    )
                    if sn.get("htmlNode")
                    else ""
                )
                serialized_snaps.append({
                    "snapshotName": sn["snapshotName"],
                    "callId": sn["callId"],
                    "phase": sn["phase"],
                    "frameUrl": sn["frameUrl"],
                    "viewport": sn["viewport"],
                    "wallTime": sn["wallTime"],
                    "html": html_str if html_str else None,
                    "title": _extract_title_from_html(html_str) if html_str else None,
                    "targetOuterHTML": target_capture[0],
                })

        screencast_frames.sort(key=lambda f: f["wallTime"] if f["wallTime"] is not None else f["mono"])
        serialized_snaps.sort(key=lambda s: s["wallTime"] if s["wallTime"] is not None else 0)

        ordered_actions = [actions_by_call[cid] for cid in action_order if cid in actions_by_call]
        return {
            "viewport": viewport,
            "baseURL": base_url,
            "screencastFrames": screencast_frames,
            "frameURICache": frame_uri_cache,
            "actions": ordered_actions,
            "inputBoxes": input_boxes,
            "snapshots": serialized_snaps,
            "consoleEvents": console_events,
            "networkEntries": network_entries,
        }


    def build_steps_from_trace_zip(zip_path, fallback_title, fallback_status, fallback_start_ms, fallback_duration_ms, fallback_error):
        parsed = parse_playwright_trace_zip(zip_path)
        if not parsed:
            return []

        steps = []
        step_metas = []
        base_url = parsed.get("baseURL")

        # Build step timeline directly from Playwright trace actions (filtering noisy internal setup unless failed)
        for act in parsed["actions"]:
            api_name = act["apiName"]
            if api_name in INTERNAL_API_NAMES and not act["error"]:
                continue
            start_ms = act["startWallMs"] if act["startWallMs"] is not None else fallback_start_ms
            end_ms = act["endWallMs"] if act["endWallMs"] is not None else start_ms
            dur_ms = max(0, int(round(end_ms - start_ms)))
            text = _format_action_step_text(act)
            params = act.get("params") or {}
            raw_selector = params.get("selector") if isinstance(params.get("selector"), str) else None
            selector = _clean_selector_display(raw_selector) if raw_selector else None
            diag = _empty_diagnostics()

            if "goto" in api_name and isinstance(params.get("url"), str):
                raw_u = params["url"]
                diag["pageURL"] = urllib.parse.urljoin(base_url, raw_u) if (base_url and not re.match(r"^https?://", raw_u)) else raw_u

            if api_name.startswith("expect.") or api_name.startswith("locator.expect") or "expect" in api_name.lower():
                method_name = api_name.split(".")[-1] if "." in api_name else api_name
                expected_val = _extract_expected_text(params) or selector
                diag["assertion"] = {
                    "method": method_name,
                    "passed": act["error"] is None,
                    "expected": expected_val,
                    "actual": act.get("actualResult"),
                    "message": act["error"],
                    "relatedRequestId": None,
                }

            step_rec = {
                "text": text,
                "depth": 0,
                "status": "failed" if act["error"] else "passed",
                "durationMs": dur_ms,
                "startedAt": _iso_from_ms(start_ms),
                "finishedAt": _iso_from_ms(end_ms),
                "targetSelector": selector,
                "errorMessage": act["error"],
                "diagnostics": diag,
            }
            steps.append(step_rec)
            step_metas.append({
                "callId": act["callId"],
                "afterSnapshot": act.get("afterSnapshot"),
                "inputSnapshot": act.get("inputSnapshot"),
                "beforeSnapshot": act.get("beforeSnapshot"),
                "startMs": start_ms,
                "endMs": end_ms,
                "apiName": api_name,
            })

        # If trace had API network calls without explicit action entries, synthesize one step per API call
        api_entries = [n for n in parsed["networkEntries"] if n["isApi"]]
        if not steps and api_entries:
            for item in api_entries:
                e = item["entry"]
                st_ms = item["startedAtMs"] if item["startedAtMs"] is not None else fallback_start_ms
                dur = e["durationMs"] or 0
                diag = _empty_diagnostics()
                diag["networkRequests"].append(e)
                steps.append({
                    "text": f'{e["method"]} {e["url"]}',
                    "depth": 0,
                    "status": "failed" if (e.get("errorText") or (e.get("status") or 200) >= 500) else "passed",
                    "durationMs": dur,
                    "startedAt": _iso_from_ms(st_ms),
                    "finishedAt": _iso_from_ms(st_ms + dur),
                    "targetSelector": None,
                    "errorMessage": e.get("errorText"),
                    "diagnostics": diag,
                })
                step_metas.append({"callId": None, "afterSnapshot": None, "inputSnapshot": None, "beforeSnapshot": None, "startMs": st_ms, "endMs": st_ms + dur, "apiName": "apiRequestContext"})
            api_entries = []

        if not steps:
            steps.append({
                "text": fallback_title,
                "depth": 0,
                "status": fallback_status,
                "durationMs": fallback_duration_ms,
                "startedAt": _iso_from_ms(fallback_start_ms),
                "finishedAt": _iso_from_ms(fallback_start_ms + fallback_duration_ms),
                "targetSelector": None,
                "errorMessage": fallback_error,
                "diagnostics": _empty_diagnostics(),
            })
            step_metas.append({
                "callId": None,
                "afterSnapshot": None,
                "inputSnapshot": None,
                "beforeSnapshot": None,
                "startMs": fallback_start_ms,
                "endMs": fallback_start_ms + fallback_duration_ms,
                "apiName": "",
            })

        # 1. Attach screencast frames (bounded by next step so early steps don't steal final frames)
        frames = parsed["screencastFrames"]
        if frames:
            uri_cache = parsed["frameURICache"]
            for idx, (step, meta) in enumerate(zip(steps, step_metas)):
                next_start = step_metas[idx + 1]["startMs"] if idx + 1 < len(step_metas) else None
                upper_after = (
                    min(meta["endMs"] + 250, next_start + 20)
                    if next_start is not None
                    else meta["endMs"] + 250
                )
                before_f = None
                before_loose = None
                after_f = None
                before_loose_cutoff = min(meta["startMs"] + 25, max(meta["startMs"], meta["endMs"] - 1))
                for f in frames:
                    wt = f["wallTime"]
                    if wt is None:
                        continue
                    if wt <= meta["startMs"]:
                        before_f = f
                    if wt <= before_loose_cutoff:
                        before_loose = f
                    if wt <= upper_after:
                        after_f = f
                if after_f is None or (before_f is not None and after_f is before_f and next_start is not None):
                    # If no frame arrived before next step started, allow the first frame captured just after endMs
                    near_f = next((f for f in frames if f["wallTime"] is not None and meta["startMs"] <= f["wallTime"] <= meta["endMs"] + 250), None)
                    if near_f is not None:
                        after_f = near_f
                if after_f is None:
                    after_f = next((f for f in frames if f["wallTime"] is not None and f["wallTime"] >= meta["startMs"]), frames[-1])
                if before_f is None and before_loose is not None and before_loose is not after_f:
                    before_f = before_loose
                if before_f is not None and before_f is not after_f:
                    step["diagnostics"]["beforeScreenshotDataURI"] = uri_cache.get(before_f["file"])
                if after_f is not None:
                    step["diagnostics"]["afterScreenshotDataURI"] = uri_cache.get(after_f["file"])

        # 2. Attach DOM snapshots & target bounding boxes
        snaps = parsed["snapshots"]
        boxes = parsed["inputBoxes"]
        if snaps:
            snaps_by_name = {s["snapshotName"]: s for s in snaps if s.get("snapshotName")}
            last_url = None
            for step, meta in zip(steps, step_metas):
                cid = meta["callId"]
                chosen = None
                for ref_key in (meta.get("afterSnapshot"), meta.get("inputSnapshot"), meta.get("beforeSnapshot")):
                    if ref_key and ref_key in snaps_by_name and snaps_by_name[ref_key].get("html"):
                        chosen = snaps_by_name[ref_key]
                        break
                if not chosen and cid:
                    chosen = next((s for s in snaps if s["callId"] == cid and s["phase"] == "after" and s.get("html")), None)
                    if not chosen:
                        chosen = next((s for s in snaps if s["callId"] == cid and s.get("html")), None)
                if not chosen:
                    for s in snaps:
                        if s.get("html") and s["wallTime"] is not None and s["wallTime"] <= meta["endMs"] + 250:
                            chosen = s
                if not chosen:
                    chosen = next((s for s in snaps if s.get("html")), snaps[0])

                # Also grab targetOuterHTML from inputSnapshot if afterSnapshot navigated away
                target_outer = chosen.get("targetOuterHTML") if chosen else None
                if not target_outer and meta.get("inputSnapshot") in snaps_by_name:
                    target_outer = snaps_by_name[meta["inputSnapshot"]].get("targetOuterHTML")

                if chosen and chosen.get("html"):
                    raw_box = boxes.get(cid) if cid else None
                    vp = chosen.get("viewport") or parsed["viewport"]
                    bbox = None
                    if raw_box:
                        bbox = {
                            "x": raw_box["x"],
                            "y": raw_box["y"],
                            "width": raw_box["width"],
                            "height": raw_box["height"],
                            "viewportWidth": vp["width"] if isinstance(vp, dict) and vp.get("width") else None,
                            "viewportHeight": vp["height"] if isinstance(vp, dict) and vp.get("height") else None,
                        }
                    step["diagnostics"]["domSnapshot"] = {
                        "html": chosen["html"],
                        "url": chosen.get("frameUrl"),
                        "title": chosen.get("title"),
                        "targetSelector": step.get("targetSelector"),
                        "targetOuterHTML": target_outer,
                        "targetBoundingBox": bbox,
                        "matchedCount": 1 if (target_outer or bbox) else None,
                    }
                    if chosen.get("frameUrl") and chosen["frameUrl"] != "about:blank":
                        last_url = chosen["frameUrl"]
                if step["diagnostics"]["pageURL"]:
                    last_url = step["diagnostics"]["pageURL"]
                elif last_url and not meta["apiName"].startswith("apiRequest"):
                    step["diagnostics"]["pageURL"] = last_url

        # 3. Attach remaining API & Browser network exchanges
        for item in api_entries:
            target_idx = 0
            api_indices = [i for i, m in enumerate(step_metas) if "apiRequest" in m["apiName"] or "request." in m["apiName"].lower()]
            pool = api_indices if api_indices else list(range(len(steps)))
            if item["startedAtMs"] is not None:
                best_dist = float("inf")
                for i in pool:
                    d = abs(item["startedAtMs"] - step_metas[i]["startMs"])
                    if d < best_dist:
                        best_dist = d
                        target_idx = i
            else:
                target_idx = pool[0]
            steps[target_idx]["diagnostics"]["networkRequests"].append(item["entry"])

        browser_entries = [n for n in parsed["networkEntries"] if not n["isApi"]]
        if browser_entries:
            def _prio(item):
                e = item["entry"]
                if e.get("errorText") or (e.get("status") or 0) >= 400:
                    return 0
                if e.get("resourceType") in ("fetch", "xhr", "document"):
                    return 1
                return 2

            for item in sorted(browser_entries, key=_prio):
                target_idx = 0
                wt = item["startedAtMs"]
                if wt is not None:
                    matched = False
                    for i, m in enumerate(step_metas):
                        if m["startMs"] <= wt <= m["endMs"]:
                            target_idx = i
                            matched = True
                            break
                    if not matched:
                        for i, m in enumerate(step_metas):
                            if m["startMs"] - 150 <= wt <= m["endMs"] + 250:
                                target_idx = i
                                break
                if len(steps[target_idx]["diagnostics"]["networkRequests"]) < MAX_BROWSER_NET_PER_STEP:
                    steps[target_idx]["diagnostics"]["networkRequests"].append(item["entry"])

        # 4. Attach console & pageerror events
        for c in parsed["consoleEvents"]:
            if not c["entry"]["message"]:
                continue
            target_idx = len(steps) - 1
            wt = c["wallTime"]
            if wt is not None:
                matched = False
                for i, m in enumerate(step_metas):
                    if m["startMs"] <= wt <= m["endMs"]:
                        target_idx = i
                        matched = True
                        break
                if not matched:
                    for i, m in enumerate(step_metas):
                        if m["startMs"] - 150 <= wt <= m["endMs"] + 250:
                            target_idx = i
                            break
            steps[target_idx]["diagnostics"]["consoleEntries"].append(c["entry"])

        # 5. Link API assertions to their preceding API request
        _link_api_assertions(steps)
        return steps


    def _link_api_assertions(steps):
        last_api_id = None
        for step in steps:
            diag = step.get("diagnostics") or {}
            api_reqs = [
                r for r in (diag.get("networkRequests") or [])
                if r.get("source") in ("playwright-api", "playwright-python-api") or r.get("resourceType") == "api"
            ]
            if api_reqs:
                last_api_id = api_reqs[-1]["id"]
            assertion = diag.get("assertion")
            if assertion and not assertion.get("relatedRequestId") and last_api_id:
                if not _is_web_assertion(assertion.get("method")):
                    assertion["relatedRequestId"] = last_api_id


    def _merge_trace_and_live_steps(trace_steps, live_steps):
        if not live_steps:
            return trace_steps
        if not trace_steps:
            merged = list(live_steps)
            _link_api_assertions(merged)
            return merged

        # Deduplicate live API calls that trace.zip already captured via `_apiRequestRef`
        existing_api_sigs = set()
        for s in trace_steps:
            for r in (s.get("diagnostics") or {}).get("networkRequests") or []:
                if r.get("source") in ("playwright-api", "playwright-python-api") or r.get("resourceType") == "api":
                    existing_api_sigs.add((r.get("method"), r.get("url")))

        extras = []
        for ls in live_steps:
            reqs = (ls.get("diagnostics") or {}).get("networkRequests") or []
            if reqs and all((r.get("method"), r.get("url")) in existing_api_sigs for r in reqs):
                continue
            extras.append(ls)

        if not extras:
            return trace_steps

        combined = list(trace_steps) + extras
        combined.sort(key=lambda s: _parse_iso_ms(s.get("startedAt")) or 0)
        _link_api_assertions(combined)
        return combined


    def _install_playwright_api_hooks():
        """Safely instrument Playwright Python's APIRequestContext & APIResponseAssertions
        so pure API tests (without BrowserContext/page) and hybrid tests capture full HTTP
        exchanges and assertions even when pytest-playwright writes no trace.zip."""
        global _HOOKS_INSTALLED
        if _HOOKS_INSTALLED:
            return
        _HOOKS_INSTALLED = True

        try:
            from playwright._impl import _fetch as pw_fetch
            orig_inner_fetch = getattr(pw_fetch.APIRequestContext, "_inner_fetch", None)
            if orig_inner_fetch and not getattr(orig_inner_fetch, "_ceptra_wrapped", False):
                param_names = list(orig_inner_fetch.__code__.co_varnames[1:orig_inner_fetch.__code__.co_argcount])

                def _extract_arg(name, args, kwargs):
                    if name in kwargs:
                        return kwargs[name]
                    if name in param_names:
                        idx = param_names.index(name)
                        if idx < len(args):
                            return args[idx]
                    return None

                def _serialize_req_body(data, form, request_obj):
                    try:
                        if data is not None:
                            if isinstance(data, (dict, list, int, float, bool)):
                                return _truncate(json.dumps(data), MAX_API_BODY_CHARS)
                            if isinstance(data, bytes):
                                return _truncate(data.decode("utf-8", errors="replace"), MAX_API_BODY_CHARS)
                            if isinstance(data, str):
                                return _truncate(data, MAX_API_BODY_CHARS)
                        if form is not None:
                            if isinstance(form, dict):
                                return _truncate(urllib.parse.urlencode(form), MAX_API_BODY_CHARS)
                            fields = getattr(form, "_fields", None)
                            if isinstance(fields, list):
                                return _truncate(urllib.parse.urlencode(fields), MAX_API_BODY_CHARS)
                        if request_obj is not None:
                            pbuf = getattr(request_obj, "post_data_buffer", None)
                            if isinstance(pbuf, (bytes, bytearray)) and pbuf:
                                return _truncate(bytes(pbuf).decode("utf-8", errors="replace"), MAX_API_BODY_CHARS)
                    except Exception:
                        pass
                    return None

                async def _ceptra_inner_fetch(self, *args, **kwargs):
                    plugin = _ACTIVE_PLUGIN
                    if plugin is None or not plugin._active_nodeid:
                        return await orig_inner_fetch(self, *args, **kwargs)

                    req_obj = _extract_arg("request", args, kwargs)
                    raw_url = _extract_arg("url", args, kwargs) or (getattr(req_obj, "url", None) if req_obj else "") or ""
                    raw_method = _extract_arg("method", args, kwargs) or (getattr(req_obj, "method", None) if req_obj else None) or "GET"
                    req_method = str(raw_method).upper()
                    raw_headers = _extract_arg("headers", args, kwargs) or (getattr(req_obj, "headers", None) if req_obj else None)
                    req_body = _serialize_req_body(_extract_arg("data", args, kwargs), _extract_arg("form", args, kwargs), req_obj)
                    req_headers = _redact_headers(raw_headers) if raw_headers else {}

                    start_ms = int(round(time.time() * 1000.0))
                    t0 = time.monotonic()
                    try:
                        resp = await orig_inner_fetch(self, *args, **kwargs)
                    except Exception as exc:
                        dur_ms = max(0, int(round((time.monotonic() - t0) * 1000.0)))
                        end_ms = start_ms + dur_ms
                        err_txt = _truncate(_strip_ansi(str(exc)), MAX_ERROR_CHARS)
                        entry = {
                            "id": str(uuid.uuid4()),
                            "method": req_method,
                            "url": str(raw_url),
                            "resourceType": "api",
                            "source": "playwright-python-api",
                            "status": None,
                            "statusText": None,
                            "startedAt": _iso_from_ms(start_ms),
                            "durationMs": dur_ms,
                            "requestSizeBytes": len(req_body.encode("utf-8")) if req_body else None,
                            "responseSizeBytes": None,
                            "timings": {"dnsMs": None, "connectMs": None, "tlsMs": None, "ttfbMs": None, "downloadMs": None, "totalMs": dur_ms},
                            "requestHeaders": req_headers,
                            "responseHeaders": {},
                            "requestBody": req_body,
                            "responseBody": None,
                            "errorText": err_txt,
                        }
                        diag = _empty_diagnostics()
                        diag["networkRequests"].append(entry)
                        plugin._record_live_step({
                            "text": f"{req_method} {raw_url}",
                            "depth": 0,
                            "status": "failed",
                            "durationMs": dur_ms,
                            "startedAt": _iso_from_ms(start_ms),
                            "finishedAt": _iso_from_ms(end_ms),
                            "targetSelector": None,
                            "errorMessage": err_txt,
                            "diagnostics": diag,
                        })
                        raise

                    dur_ms = max(0, int(round((time.monotonic() - t0) * 1000.0)))
                    end_ms = start_ms + dur_ms
                    try:
                        res_url = str(getattr(resp, "url", None) or raw_url)
                        res_status = getattr(resp, "status", None)
                        res_status_text = getattr(resp, "status_text", None)
                        res_headers_arr = getattr(resp, "headers_array", None)
                        res_headers = _redact_headers(res_headers_arr if res_headers_arr else getattr(resp, "headers", None))
                        ctype = ""
                        for hk, hv in res_headers.items():
                            if hk.lower() == "content-type":
                                ctype = hv
                                break

                        res_body = None
                        res_size = None
                        try:
                            raw_bytes = await resp.body()
                            if isinstance(raw_bytes, (bytes, bytearray)):
                                res_size = len(raw_bytes)
                                if not ctype or _is_text_mime(ctype):
                                    res_body = _truncate(raw_bytes.decode("utf-8", errors="replace"), MAX_API_BODY_CHARS)
                        except Exception:
                            pass

                        entry_id = str(uuid.uuid4())
                        try:
                            setattr(resp, "_ceptra_req_id", entry_id)
                        except Exception:
                            pass

                        entry = {
                            "id": entry_id,
                            "method": req_method,
                            "url": res_url,
                            "resourceType": "api",
                            "source": "playwright-python-api",
                            "status": int(res_status) if isinstance(res_status, int) else None,
                            "statusText": str(res_status_text) if res_status_text else None,
                            "startedAt": _iso_from_ms(start_ms),
                            "durationMs": dur_ms,
                            "requestSizeBytes": len(req_body.encode("utf-8")) if req_body else None,
                            "responseSizeBytes": res_size,
                            "timings": {"dnsMs": None, "connectMs": None, "tlsMs": None, "ttfbMs": None, "downloadMs": None, "totalMs": dur_ms},
                            "requestHeaders": req_headers,
                            "responseHeaders": res_headers,
                            "requestBody": req_body,
                            "responseBody": res_body,
                            "errorText": None,
                        }
                        diag = _empty_diagnostics()
                        diag["networkRequests"].append(entry)
                        plugin._record_live_step({
                            "text": f"{req_method} {res_url}",
                            "depth": 0,
                            "status": "passed",
                            "durationMs": dur_ms,
                            "startedAt": _iso_from_ms(start_ms),
                            "finishedAt": _iso_from_ms(end_ms),
                            "targetSelector": None,
                            "errorMessage": None,
                            "diagnostics": diag,
                        })
                    except Exception:
                        pass
                    return resp

                _ceptra_inner_fetch._ceptra_wrapped = True
                pw_fetch.APIRequestContext._inner_fetch = _ceptra_inner_fetch
        except Exception:
            pass

        try:
            from playwright._impl import _assertions as pw_assertions
            orig_to_be_ok = getattr(pw_assertions.APIResponseAssertions, "to_be_ok", None)
            if orig_to_be_ok and not getattr(orig_to_be_ok, "_ceptra_wrapped", False):
                async def _ceptra_to_be_ok(self, *args, **kwargs):
                    plugin = _ACTIVE_PLUGIN
                    if plugin is None or not plugin._active_nodeid:
                        return await orig_to_be_ok(self, *args, **kwargs)

                    is_not = bool(getattr(self, "_is_not", False))
                    actual_resp = getattr(self, "_actual", None)
                    method_name = "not_to_be_ok" if is_not else "to_be_ok"
                    step_text = f"expect(response).{method_name}()"
                    rel_id = getattr(actual_resp, "_ceptra_req_id", None)
                    actual_status = getattr(actual_resp, "status", None)
                    expected_str = "status not in 200..299" if is_not else "status in 200..299"
                    actual_str = f"HTTP {actual_status}" if actual_status is not None else None

                    start_ms = int(round(time.time() * 1000.0))
                    t0 = time.monotonic()
                    try:
                        res = await orig_to_be_ok(self, *args, **kwargs)
                    except Exception as exc:
                        dur_ms = max(0, int(round((time.monotonic() - t0) * 1000.0)))
                        err_txt = _truncate(_strip_ansi(str(exc)), MAX_ERROR_CHARS)
                        diag = _empty_diagnostics()
                        diag["assertion"] = {
                            "method": method_name,
                            "passed": False,
                            "expected": expected_str,
                            "actual": actual_str,
                            "message": err_txt,
                            "relatedRequestId": rel_id,
                        }
                        plugin._record_live_step({
                            "text": step_text,
                            "depth": 0,
                            "status": "failed",
                            "durationMs": dur_ms,
                            "startedAt": _iso_from_ms(start_ms),
                            "finishedAt": _iso_from_ms(start_ms + dur_ms),
                            "targetSelector": None,
                            "errorMessage": err_txt,
                            "diagnostics": diag,
                        })
                        raise

                    dur_ms = max(0, int(round((time.monotonic() - t0) * 1000.0)))
                    diag = _empty_diagnostics()
                    diag["assertion"] = {
                        "method": method_name,
                        "passed": True,
                        "expected": expected_str,
                        "actual": actual_str,
                        "message": None,
                        "relatedRequestId": rel_id,
                    }
                    plugin._record_live_step({
                        "text": step_text,
                        "depth": 0,
                        "status": "passed",
                        "durationMs": dur_ms,
                        "startedAt": _iso_from_ms(start_ms),
                        "finishedAt": _iso_from_ms(start_ms + dur_ms),
                        "targetSelector": None,
                        "errorMessage": None,
                        "diagnostics": diag,
                    })
                    return res

                _ceptra_to_be_ok._ceptra_wrapped = True
                pw_assertions.APIResponseAssertions.to_be_ok = _ceptra_to_be_ok
        except Exception:
            pass


    def _slugify_nodeid(nodeid):
        # Matches pytest-playwright's `slugify` artifact directory naming
        cleaned = re.sub(r"[^a-zA-Z0-9]+", "-", nodeid).strip("-").lower()
        return cleaned


    def _find_trace_and_screenshots(output_dir, nodeid, start_epoch_sec):
        if not output_dir or not os.path.isdir(output_dir):
            return None, []
        slug = _slugify_nodeid(nodeid)
        candidate_dirs = []
        exact = os.path.join(output_dir, slug)
        if os.path.isdir(exact):
            candidate_dirs.append(exact)
        else:
            # Fallback: match truncated slug prefix or suffix
            short_slug = slug[:48]
            try:
                for entry in os.scandir(output_dir):
                    if not entry.is_dir():
                        continue
                    lower_name = entry.name.lower()
                    if short_slug and (lower_name.startswith(short_slug) or slug.endswith(lower_name)):
                        candidate_dirs.append(entry.path)
            except OSError:
                pass

        trace_path = None
        screenshots = []
        for d in candidate_dirs:
            tzip = os.path.join(d, "trace.zip")
            if os.path.isfile(tzip):
                try:
                    if os.path.getmtime(tzip) >= start_epoch_sec - 5.0:
                        trace_path = tzip
                except OSError:
                    trace_path = tzip
            try:
                for f in os.scandir(d):
                    if f.is_file() and f.name.lower().endswith((".png", ".jpg", ".jpeg", ".webp")):
                        screenshots.append(f.path)
            except OSError:
                pass
            if trace_path or screenshots:
                break
        return trace_path, screenshots


    def _image_to_data_uri(img_path):
        try:
            st = os.stat(img_path)
            if st.st_size <= 0 or st.st_size > MAX_ATTACHMENT_BYTES:
                return None
            with open(img_path, "rb") as fh:
                raw = fh.read()
            ext = os.path.splitext(img_path)[1].lower()
            mime = "image/png" if ext == ".png" else ("image/webp" if ext == ".webp" else "image/jpeg")
            return f"data:{mime};base64,{base64.b64encode(raw).decode('ascii')}"
        except Exception:
            return None


    class CeptraPytestPlaywrightPlugin:
        def __init__(self, output_dir, pw_output_dir):
            self.output_dir = output_dir
            self.pw_output_dir = pw_output_dir
            self.worker_file = (
                os.path.join(output_dir, f"worker-{os.getpid()}-{uuid.uuid4().hex[:8]}.json")
                if output_dir else ""
            )
            self.scenarios = []
            self._meta_by_nodeid = {}
            self._start_by_nodeid = {}
            self._records_by_nodeid = {}
            self._call_info_by_nodeid = {}
            self._hydrated_nodeids = set()
            self._live_steps_by_nodeid = {}
            self._active_nodeid = None

        def _record_live_step(self, step):
            nid = self._active_nodeid
            if not nid:
                return
            self._live_steps_by_nodeid.setdefault(nid, []).append(step)

        def pytest_runtest_setup(self, item):
            self._active_nodeid = item.nodeid
            self._start_by_nodeid[item.nodeid] = time.time()
            self._live_steps_by_nodeid[item.nodeid] = []
            markers = []
            for mark in item.iter_markers():
                name = str(mark.name or "").strip()
                if name and name not in ("parametrize", "usefixtures", "filterwarnings"):
                    markers.append(f"@{name}")
            file_path = str(getattr(item, "path", None) or getattr(item, "fspath", "") or "")
            self._meta_by_nodeid[item.nodeid] = {
                "filePath": file_path or None,
                "tags": sorted(set(markers)),
            }

        def _finalize_steps(self, steps, shot_paths, console_entries, status, err_msg):
            if shot_paths:
                target = next((s for s in steps if s["status"] == "failed"), steps[-1])
                for sp in shot_paths:
                    uri = _image_to_data_uri(sp)
                    if uri:
                        if not target["diagnostics"]["afterScreenshotDataURI"]:
                            target["diagnostics"]["afterScreenshotDataURI"] = uri
                        elif not target["diagnostics"]["beforeScreenshotDataURI"]:
                            target["diagnostics"]["beforeScreenshotDataURI"] = target["diagnostics"]["afterScreenshotDataURI"]
                            target["diagnostics"]["afterScreenshotDataURI"] = uri

            if console_entries:
                existing_msgs = {
                    (c.get("level"), c.get("message"))
                    for c in steps[-1]["diagnostics"]["consoleEntries"]
                }
                for ce in console_entries:
                    key = (ce.get("level"), ce.get("message"))
                    if key not in existing_msgs:
                        steps[-1]["diagnostics"]["consoleEntries"].append(ce)
                        existing_msgs.add(key)

            if status == "failed" and not any(s["status"] == "failed" for s in steps):
                steps[-1]["status"] = "failed"
                if not steps[-1]["errorMessage"]:
                    steps[-1]["errorMessage"] = err_msg

        def _hydrate_record_from_trace(self, nodeid):
            if nodeid in self._hydrated_nodeids:
                return False
            record = self._records_by_nodeid.get(nodeid)
            info = self._call_info_by_nodeid.get(nodeid)
            if not record or not info:
                return False

            trace_zip, shot_paths = _find_trace_and_screenshots(self.pw_output_dir, nodeid, info["startSec"])
            if not trace_zip and not shot_paths:
                return False

            live_steps = list(self._live_steps_by_nodeid.get(nodeid) or [])
            trace_steps = []
            if trace_zip:
                trace_steps = build_steps_from_trace_zip(
                    trace_zip,
                    info["scenarioTitle"],
                    record["status"],
                    info["startMs"],
                    info["durMs"],
                    record["errorMessage"],
                )

            if trace_steps:
                steps = _merge_trace_and_live_steps(trace_steps, live_steps)
                self._finalize_steps(steps, shot_paths, info["consoleEntries"], record["status"], record["errorMessage"])
                record["steps"] = steps
                self._hydrated_nodeids.add(nodeid)
                return True

            if shot_paths and record.get("steps"):
                self._finalize_steps(record["steps"], shot_paths, info["consoleEntries"], record["status"], record["errorMessage"])
                self._hydrated_nodeids.add(nodeid)
                return True

            return False

        def pytest_runtest_logreport(self, report):
            nodeid = str(report.nodeid)

            # Teardown phase runs AFTER pytest-playwright's `context` fixture saves `trace.zip`!
            if report.when == "teardown":
                if self._active_nodeid == nodeid:
                    self._active_nodeid = None
                existing = self._records_by_nodeid.get(nodeid)
                if existing is not None:
                    if report.failed:
                        longrepr = _strip_ansi(str(getattr(report, "longreprtext", "") or getattr(report, "longrepr", "") or ""))
                        err_stack = _truncate(longrepr, MAX_ERROR_CHARS)
                        err_lines = [ln.strip() for ln in longrepr.splitlines() if ln.strip().startswith("E ")]
                        err_msg = _truncate("\n".join(err_lines) if err_lines else (longrepr.splitlines()[-1] if longrepr else "Teardown failed"), MAX_ERROR_CHARS)
                        existing["status"] = "failed"
                        existing["errorMessage"] = existing["errorMessage"] or err_msg
                        existing["errorStack"] = existing["errorStack"] or err_stack
                    self._hydrate_record_from_trace(nodeid)
                    if existing["status"] == "failed" and existing.get("steps") and not any(s["status"] == "failed" for s in existing["steps"]):
                        existing["steps"][-1]["status"] = "failed"
                        if not existing["steps"][-1]["errorMessage"]:
                            existing["steps"][-1]["errorMessage"] = existing["errorMessage"]
                    self._flush_sync()
                    return
                if not report.failed:
                    return
            elif report.when == "call":
                if self._active_nodeid == nodeid:
                    self._active_nodeid = None
            elif report.when == "setup" and (report.skipped or report.failed):
                if self._active_nodeid == nodeid:
                    self._active_nodeid = None
            else:
                return

            meta = self._meta_by_nodeid.get(nodeid, {})
            start_sec = self._start_by_nodeid.get(nodeid, time.time() - float(getattr(report, "duration", 0.0) or 0.0))
            dur_ms = max(0, int(round(float(getattr(report, "duration", 0.0) or 0.0) * 1000.0)))
            start_ms = int(round(start_sec * 1000.0))
            end_ms = start_ms + dur_ms

            # Parse nodeid like `tests/test_example.py::TestDocs::test_has_title[chromium]`
            parts = nodeid.split("::")
            rel_file = parts[0] if parts else ""
            raw_test = parts[-1] if len(parts) >= 2 else nodeid
            browser_match = re.search(r"\[(chromium|firefox|webkit)\]$", raw_test)
            browser_name = browser_match.group(1) if browser_match else None
            scenario_title = raw_test[: browser_match.start()] if browser_match else raw_test

            if len(parts) >= 3:
                suite_stem = " › ".join(parts[1:-1])
            else:
                suite_stem = Path(rel_file).stem or "pytest"
            feature_title = f"[{browser_name}] {suite_stem}" if browser_name else suite_stem

            status = "passed"
            if report.failed:
                status = "failed"
            elif report.skipped:
                status = "skipped"

            err_msg = None
            err_stack = None
            if report.failed:
                longrepr = _strip_ansi(str(getattr(report, "longreprtext", "") or getattr(report, "longrepr", "") or ""))
                err_stack = _truncate(longrepr, MAX_ERROR_CHARS)
                # Extract concise assertion/error line
                err_lines = [ln.strip() for ln in longrepr.splitlines() if ln.strip().startswith("E ")]
                err_msg = _truncate("\n".join(err_lines) if err_lines else (longrepr.splitlines()[-1] if longrepr else "Test failed"), MAX_ERROR_CHARS)

            console_entries = []
            for cap_attr, lvl in (("capstdout", "log"), ("capstderr", "error")):
                cap_txt = _strip_ansi(str(getattr(report, cap_attr, "") or "")).strip()
                if cap_txt:
                    console_entries.append({
                        "id": str(uuid.uuid4()),
                        "level": lvl,
                        "message": _truncate(cap_txt, MAX_CONSOLE_CHARS),
                        "timestamp": _iso_from_ms(end_ms),
                        "sourceURL": None,
                        "lineNumber": None,
                    })

            live_steps = list(self._live_steps_by_nodeid.get(nodeid) or [])
            trace_zip, shot_paths = _find_trace_and_screenshots(self.pw_output_dir, nodeid, start_sec)
            trace_steps = []
            if trace_zip:
                trace_steps = build_steps_from_trace_zip(trace_zip, scenario_title, status, start_ms, dur_ms, err_msg)

            steps = _merge_trace_and_live_steps(trace_steps, live_steps)
            if trace_steps:
                self._hydrated_nodeids.add(nodeid)

            if not steps:
                steps = [{
                    "text": scenario_title,
                    "depth": 0,
                    "status": "failed" if status == "failed" else "passed",
                    "durationMs": dur_ms,
                    "startedAt": _iso_from_ms(start_ms),
                    "finishedAt": _iso_from_ms(end_ms),
                    "targetSelector": None,
                    "errorMessage": err_msg,
                    "diagnostics": _empty_diagnostics(),
                }]

            self._finalize_steps(steps, shot_paths, console_entries, status, err_msg)

            record = {
                "featureTitle": feature_title,
                "scenarioTitle": scenario_title,
                "filePath": meta.get("filePath") or rel_file or None,
                "status": status,
                "durationMs": dur_ms,
                "startedAt": _iso_from_ms(start_ms),
                "finishedAt": _iso_from_ms(end_ms),
                "tags": meta.get("tags") or [],
                "errorMessage": err_msg,
                "errorStack": err_stack,
                "steps": steps,
            }

            self._call_info_by_nodeid[nodeid] = {
                "scenarioTitle": scenario_title,
                "startSec": start_sec,
                "startMs": start_ms,
                "durMs": dur_ms,
                "consoleEntries": console_entries,
            }
            self._records_by_nodeid[nodeid] = record
            self.scenarios.append(record)
            self._flush_sync()

        def pytest_sessionfinish(self, session, exitstatus):
            # Final fallback hydration pass for any trace.zip flushed late during session teardown
            for nid in list(self._records_by_nodeid.keys()):
                if nid not in self._hydrated_nodeids:
                    self._hydrate_record_from_trace(nid)
            self._flush_sync()

        def _flush_sync(self):
            if not self.output_dir or not self.worker_file:
                return
            try:
                os.makedirs(self.output_dir, exist_ok=True)
                payload = {
                    "version": 1,
                    "workerPid": os.getpid(),
                    "scenarios": self.scenarios,
                }
                tmp = self.worker_file + ".tmp"
                with open(tmp, "w", encoding="utf-8") as fh:
                    json.dump(payload, fh)
                os.replace(tmp, self.worker_file)
            except Exception:
                pass


    def pytest_configure(config):
        global _ACTIVE_PLUGIN
        output_dir = os.environ.get("CEPTRA_TIME_TRAVEL_DIR", "")
        if not output_dir:
            return
        pw_output_dir = os.environ.get("CEPTRA_PW_OUTPUT_DIR", "")
        if not pw_output_dir:
            try:
                pw_output_dir = str(config.getoption("--output") or "test-results")
            except Exception:
                pw_output_dir = "test-results"
        if not os.path.isabs(pw_output_dir):
            root_path = getattr(config, "rootpath", None)
            if root_path:
                pw_output_dir = os.path.abspath(os.path.join(str(root_path), pw_output_dir))
            else:
                pw_output_dir = os.path.abspath(pw_output_dir)
        plugin = CeptraPytestPlaywrightPlugin(output_dir, pw_output_dir)
        _ACTIVE_PLUGIN = plugin
        _install_playwright_api_hooks()
        config.pluginmanager.register(plugin, "ceptra_pw_time_travel_plugin")
    """#

    /// Ensures the zero-dependency Python pytest plugin exists in a whitespace-free directory
    /// and returns its parent directory URL (to prepend onto `PYTHONPATH`).
    public static func ensurePluginDirectoryURL(baseDirectory: URL? = nil) -> URL? {
        let candidateBase = baseDirectory ?? FileManager.default.temporaryDirectory
        let safeBase: URL
        if candidateBase.path.contains(" ") {
            safeBase = URL(fileURLWithPath: "/tmp", isDirectory: true)
        } else {
            safeBase = candidateBase
        }

        let dir = safeBase.appendingPathComponent(directoryName, isDirectory: true)
        let pluginURL = dir.appendingPathComponent(pluginFileName)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: pluginURL, encoding: .utf8)) != pluginScriptSource {
                try pluginScriptSource.write(to: pluginURL, atomically: true, encoding: .utf8)
            }
            return dir
        } catch {
            return nil
        }
    }
}
