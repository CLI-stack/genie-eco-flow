"""eco_html_design.py — Shared VS Code dark theme for ECO HTML email builders.

<head><style> approach confirmed working in user's Outlook.
CSS classes keep HTML clean and consistent across round + final emails.
"""
import html as _html

# ── CSS (placed in <head><style>) ─────────────────────────────────────────
CSS = """
body{font-family:Arial,Helvetica,sans-serif;background:#1e1e1e;color:#d4d4d4;padding:16px;margin:0}
h1{color:#569cd6;font-size:20px;margin-bottom:4px;border-bottom:2px solid #569cd6;padding-bottom:8px}
h2{color:#4ec9b0;font-size:15px;border-bottom:1px solid #4ec9b0;padding-bottom:4px;margin-top:20px}
h3{color:#9cdcfe;font-size:13px;margin-top:14px;margin-bottom:4px}
h4{color:#ce9178;font-size:12px;margin-top:10px;margin-bottom:3px}
a{color:#569cd6}
code{font-family:monospace;font-size:11px;color:#ce9178;background:#252526;padding:1px 4px;border-radius:3px}
pre{font-family:monospace;font-size:11px;background:#252526;color:#d4d4d4;padding:12px;border-radius:4px;white-space:pre-wrap;word-wrap:break-word;max-height:300px;overflow-y:auto;border:1px solid #3e3e3e;margin:6px 0}
p{font-size:13px;margin:6px 0;color:#d4d4d4}
ul{font-size:13px;color:#d4d4d4;margin:4px 0;padding-left:20px}
li{margin-bottom:4px}
table{border-collapse:collapse;width:100%;margin:8px 0;font-size:12px}
th{background:#252526;color:#569cd6;padding:8px 10px;text-align:left;border:1px solid #3e3e3e;font-weight:bold;white-space:nowrap}
td{padding:7px 10px;border:1px solid #3e3e3e;color:#d4d4d4;vertical-align:top;word-break:break-word}
tr:nth-child(even) td{background:#252526}
tr:nth-child(odd) td{background:#1e1e1e}
.pass{color:#4ec9b0;font-weight:bold}
.fail{color:#f48771;font-weight:bold}
.warn{color:#dcdcaa;font-weight:bold}
.abort{color:#f48771;font-weight:bold}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:bold}
.badge-pass{background:#1a3d2f;color:#4ec9b0;border:1px solid #4ec9b0}
.badge-fail{background:#3d1a1a;color:#f48771;border:1px solid #f48771}
.badge-warn{background:#3d3a1a;color:#dcdcaa;border:1px solid #dcdcaa}
.badge-info{background:#1a2a3d;color:#569cd6;border:1px solid #569cd6}
.banner{padding:12px 16px;border-radius:4px;margin:10px 0;font-size:13px}
.banner-pass{background:#1a3d2f;border:2px solid #4ec9b0}
.banner-fail{background:#3d1a1a;border:2px solid #f48771}
.banner-warn{background:#3d3a1a;border:2px solid #dcdcaa}
.box{background:#252526;border:1px solid #3e3e3e;padding:12px;border-radius:4px;margin:8px 0}
.section{background:#252526;border-left:3px solid #569cd6;padding:10px 14px;margin:10px 0;border-radius:0 4px 4px 0}
.chip{display:inline-block;background:#1a2a3d;color:#9cdcfe;padding:2px 8px;border-radius:10px;font-size:11px;margin:2px}
hr{border:none;border-top:1px solid #3e3e3e;margin:16px 0}
.meta{color:#808080;font-size:11px}
.container{max-width:900px;margin:0 auto}
"""

def esc(s):
    return _html.escape(str(s)) if s is not None else ""

def badge(status):
    st = str(status).upper()
    if st in ("PASS", "CONVERGED", "FM_PASSED"):
        cls = "badge badge-pass"
    elif st in ("FAIL", "FM_FAILED"):
        cls = "badge badge-fail"
    elif st in ("MAX_ROUNDS", "WARN", "STOP", "RERUN_SAME_ROUND"):
        cls = "badge badge-warn"
    else:
        cls = "badge badge-info"
    return f'<span class="{cls}">{esc(st)}</span>'

def section_wrap(title, content, level=2):
    tag = f"h{level}"
    return f'<{tag}>{esc(title)}</{tag}><div class="section">{content}</div>'

def tbl(headers, rows):
    hdr = "\n  " + "\n  ".join(f"<th>{h}</th>" for h in headers)
    body = ""
    for row in rows:
        cells = "\n    ".join(f"<td>{c}</td>" for c in row)
        body += f"\n  <tr>\n    {cells}\n  </tr>"
    return f"<table>\n  <tr>{hdr}\n  </tr>{body}\n</table>\n"

def pre_block(text, max_chars=5000):
    if not text:
        return '<p class="meta"><i>Not available</i></p>'
    text = text[:max_chars] + ("\n…" if len(text) > max_chars else "")
    return f"<pre>\n{esc(text)}\n</pre>\n"

def html_wrap(subject, body_content, tag="", jira="", tile=""):
    # <!DOCTYPE html> MUST be the very first line — genie_cli.py send_email()
    # checks if content starts with <!DOCTYPE or <html to detect complete HTML.
    # If it starts with <!-- comment --> it falls through to spec_to_html() which
    # strips <head><style> and outputs raw CSS as text in the email body.
    return (
        f"<!DOCTYPE html>\n"
        f"<!-- subject: {subject} -->\n"
        f"<html><head><meta charset='utf-8'>"
        f"<title>ECO {jira} — {tile}</title>"
        f"<style>{CSS}</style></head>\n"
        f"<body><div class='container'>\n"
        f"{body_content}\n"
        f"</div></body></html>"
    )
