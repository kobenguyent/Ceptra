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
        "browserContext.close", "page.close", "apiRequest.newContext",
        "apiRequestContext.dispose", "tracing.start", "tracing.stop",
        "tracing.startChunk", "tracing.stopChunk",
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


    def _serialize_pw_dom_node(node, budget, depth=0):
        if node is None or budget[0] >= MAX_DOM_CHARS or depth > 48:
            return ""
        if isinstance(node, str):
            esc = _escape_html_text(node)
            budget[0] += len(esc)
            return esc
        if not isinstance(node, list) or not node:
            return ""
        if not isinstance(node[0], str):
            return ""

        tag = node[0].lower()
        if tag in ("script", "noscript"):
            return ""

        attrs = node[1] if len(node) > 1 and isinstance(node[1], dict) else None
        attr_str = ""
        if attrs:
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
            return out

        open_tag = f"<{tag}{attr_str}>"
        budget[0] += len(open_tag)
        start_idx = 2 if attrs is not None else 1
        inner_parts = []
        for child in node[start_idx:]:
            if budget[0] >= MAX_DOM_CHARS:
                break
            inner_parts.append(_serialize_pw_dom_node(child, budget, depth + 1))
        close_tag = f"</{tag}>"
        budget[0] += len(close_tag)
        return open_tag + "".join(inner_parts) + close_tag


    def _extract_title_from_html(html):
        if not html:
            return None
        m = re.search(r"<title[^>]*>([^<]{1,200})</title>", html, re.IGNORECASE)
        return m.group(1).strip() if m else None


    def _redact_headers(headers_arr):
        out = {}
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
            return title
        if api_name:
            if "goto" in api_name and isinstance(params.get("url"), str):
                return f'page.goto("{params["url"]}")'
            if isinstance(params.get("selector"), str):
                return f'{api_name}("{params["selector"]}")'
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
        screencast_frames = []
        actions_by_call = {}
        action_order = []
        input_boxes = {}
        frame_snapshots = []
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
                        act = {
                            "callId": cid,
                            "apiName": str(ev.get("apiName") or ""),
                            "title": str(ev.get("title") or ""),
                            "method": str(ev.get("method") or ""),
                            "params": ev.get("params") if isinstance(ev.get("params"), dict) else {},
                            "startWallMs": w,
                            "endWallMs": w,
                            "startMono": ev.get("startTime") if isinstance(ev.get("startTime"), (int, float)) else None,
                            "error": None,
                        }
                        if cid not in actions_by_call:
                            action_order.append(cid)
                        actions_by_call[cid] = act
                    elif etype == "after" and ev.get("callId"):
                        act = actions_by_call.get(str(ev["callId"]))
                        if act:
                            end_mono = ev.get("endTime")
                            if isinstance(end_mono, (int, float)) and act["startMono"] is not None and act["startWallMs"] is not None:
                                act["endWallMs"] = act["startWallMs"] + max(0.0, float(end_mono) - float(act["startMono"]))
                            if ev.get("error"):
                                err = ev["error"]
                                msg = err.get("message") if isinstance(err, dict) else str(err)
                                act["error"] = _truncate(_strip_ansi(str(msg or "")), MAX_ERROR_CHARS)
                    elif etype == "input" and ev.get("callId"):
                        cid = str(ev["callId"])
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
                        frame_snapshots.append({
                            "callId": snap.get("callId"),
                            "phase": "before" if sname.startswith("before") else "after",
                            "frameUrl": snap.get("frameUrl"),
                            "viewport": snap.get("viewport") or viewport,
                            "wallTime": swall,
                            "htmlNode": snap.get("html"),
                        })
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

            # Cache frame data URIs & serialized DOM snapshots while zipfile is open
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
                html_str = _serialize_pw_dom_node(sn["htmlNode"], [0], 0) if sn.get("htmlNode") else ""
                serialized_snaps.append({
                    "callId": sn["callId"],
                    "phase": sn["phase"],
                    "frameUrl": sn["frameUrl"],
                    "viewport": sn["viewport"],
                    "wallTime": sn["wallTime"],
                    "html": html_str if html_str else None,
                    "title": _extract_title_from_html(html_str) if html_str else None,
                })

        screencast_frames.sort(key=lambda f: f["wallTime"] if f["wallTime"] is not None else f["mono"])
        serialized_snaps.sort(key=lambda s: s["wallTime"] if s["wallTime"] is not None else 0)

        ordered_actions = [actions_by_call[cid] for cid in action_order if cid in actions_by_call]
        return {
            "viewport": viewport,
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
            selector = params.get("selector") if isinstance(params.get("selector"), str) else None
            diag = _empty_diagnostics()

            if "goto" in api_name and isinstance(params.get("url"), str):
                diag["pageURL"] = params["url"]

            if api_name.startswith("expect.") or api_name.startswith("locator.expect") or "expect" in api_name.lower():
                method_name = api_name.split(".")[-1] if "." in api_name else api_name
                diag["assertion"] = {
                    "method": method_name,
                    "passed": act["error"] is None,
                    "expected": None,
                    "actual": None,
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
                step_metas.append({"callId": None, "startMs": st_ms, "endMs": st_ms + dur, "apiName": "apiRequestContext"})
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
                "startMs": fallback_start_ms,
                "endMs": fallback_start_ms + fallback_duration_ms,
                "apiName": "",
            })

        # 1. Attach screencast frames
        frames = parsed["screencastFrames"]
        if frames:
            uri_cache = parsed["frameURICache"]
            for step, meta in zip(steps, step_metas):
                before_f = None
                after_f = None
                for f in frames:
                    wt = f["wallTime"]
                    if wt is None:
                        continue
                    if wt <= meta["startMs"] + 40:
                        before_f = f
                    if wt <= meta["endMs"] + 250:
                        after_f = f
                if after_f is None:
                    after_f = next((f for f in frames if f["wallTime"] is not None and f["wallTime"] >= meta["startMs"]), frames[-1])
                if before_f is not None and before_f is not after_f:
                    step["diagnostics"]["beforeScreenshotDataURI"] = uri_cache.get(before_f["file"])
                if after_f is not None:
                    step["diagnostics"]["afterScreenshotDataURI"] = uri_cache.get(after_f["file"])

        # 2. Attach DOM snapshots & target bounding boxes
        snaps = parsed["snapshots"]
        boxes = parsed["inputBoxes"]
        if snaps:
            last_url = None
            for step, meta in zip(steps, step_metas):
                cid = meta["callId"]
                chosen = None
                if cid:
                    chosen = next((s for s in snaps if s["callId"] == cid and s["phase"] == "after"), None)
                    if not chosen:
                        chosen = next((s for s in snaps if s["callId"] == cid), None)
                if not chosen:
                    for s in snaps:
                        if s["wallTime"] is not None and s["wallTime"] <= meta["endMs"] + 250:
                            chosen = s
                if not chosen:
                    chosen = snaps[0]

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
                        "targetOuterHTML": None,
                        "targetBoundingBox": bbox,
                        "matchedCount": None,
                    }
                    if chosen.get("frameUrl"):
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
        last_api_id = None
        for step in steps:
            api_reqs = [
                r for r in step["diagnostics"]["networkRequests"]
                if r.get("source") in ("playwright-api", "playwright-python-api") or r.get("resourceType") == "api"
            ]
            if api_reqs:
                last_api_id = api_reqs[-1]["id"]
            assertion = step["diagnostics"].get("assertion")
            if assertion and not assertion.get("relatedRequestId") and last_api_id:
                if not _is_web_assertion(assertion.get("method")):
                    assertion["relatedRequestId"] = last_api_id

        return steps


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
            # Fallback: match truncated slug prefix or freshly modified folder
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

        def pytest_runtest_setup(self, item):
            self._start_by_nodeid[item.nodeid] = time.time()
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

        def pytest_runtest_logreport(self, report):
            # Record on `call` phase, or on `setup` when skipped/failed before call
            if report.when == "call":
                pass
            elif report.when == "setup" and (report.skipped or report.failed):
                pass
            elif report.when == "teardown" and report.failed:
                pass
            else:
                return

            nodeid = str(report.nodeid)
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
                err_msg = _truncate("\n".join(err_lines) if err_lines else longrepr.splitlines()[-1] if longrepr else "Test failed", MAX_ERROR_CHARS)

            trace_zip, shot_paths = _find_trace_and_screenshots(self.pw_output_dir, nodeid, start_sec)
            steps = []
            if trace_zip:
                steps = build_steps_from_trace_zip(trace_zip, scenario_title, status, start_ms, dur_ms, err_msg)

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

            # Attach direct screenshot files if any were saved alongside trace
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

            # Attach captured stdout/stderr logs
            for cap_attr, lvl in (("capstdout", "log"), ("capstderr", "error")):
                cap_txt = _strip_ansi(str(getattr(report, cap_attr, "") or "")).strip()
                if cap_txt:
                    steps[-1]["diagnostics"]["consoleEntries"].append({
                        "id": str(uuid.uuid4()),
                        "level": lvl,
                        "message": _truncate(cap_txt, MAX_CONSOLE_CHARS),
                        "timestamp": _iso_from_ms(end_ms),
                        "sourceURL": None,
                        "lineNumber": None,
                    })

            # If test failed after trace actions passed (e.g. Python `assert payload["id"] == 2`), mark final step failed
            if status == "failed" and not any(s["status"] == "failed" for s in steps):
                steps[-1]["status"] = "failed"
                if not steps[-1]["errorMessage"]:
                    steps[-1]["errorMessage"] = err_msg

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

            # Avoid duplicate record if teardown also fails on an already-recorded test
            if report.when == "teardown":
                for idx, existing in enumerate(self.scenarios):
                    if existing["featureTitle"] == feature_title and existing["scenarioTitle"] == scenario_title:
                        existing["status"] = "failed"
                        existing["errorMessage"] = existing["errorMessage"] or err_msg
                        existing["errorStack"] = existing["errorStack"] or err_stack
                        self._flush_sync()
                        return

            self.scenarios.append(record)
            self._flush_sync()

        def pytest_sessionfinish(self, session, exitstatus):
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
            pw_output_dir = os.path.abspath(pw_output_dir)
        plugin = CeptraPytestPlaywrightPlugin(output_dir, pw_output_dir)
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
