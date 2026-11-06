#!/usr/bin/env python3
# Writes lsp/test/session.in, the recorded session `zig build test-lsp` feeds morphl-lsp;
# its replies must equal lsp/test/session.out byte for byte. After changing the session
# or the server, regenerate both from the repository root:
#
#   python3 lsp/test/session.py > lsp/test/session.in
#   zig-out/bin/morphl-lsp < lsp/test/session.in > lsp/test/session.out
#
# and read the new .out before committing it. Every path is under /nonexistent, so the
# replies do not depend on where the repository is: the documents' text comes from the
# messages, and an `$import` that fails names the path it tried.
import json
import sys

uri = "file:///nonexistent/ws/a%20b.mpl"
# A document over the server's 64 KiB read, so one message takes several reads, with an
# error on its last line.
big = "// filler\n" * 7000 + "$decl z $call add (1, \"q\")\n"

msgs = [
    {"id": 1, "method": "initialize",
     "params": {"rootUri": "file:///nonexistent/ws", "capabilities": {},
                "initializationOptions": {"roots": ["lib", "/abs/lib"]}}},
    {"method": "initialized", "params": {}},
    # A type error, an unknown name after text needing two UTF-16 units, an import that
    # cannot be read.
    {"method": "textDocument/didOpen",
     "params": {"textDocument": {"uri": uri, "languageId": "morphl", "version": 1,
                "text": "$decl a $call add (1, \"x\")\n$decl s \"é😀\"  $decl b zz\n"
                        "$decl m $import \"nope\"\n"}}},
    # Clean, then two syntax errors.
    {"method": "textDocument/didChange",
     "params": {"textDocument": {"uri": uri, "version": 2},
                "contentChanges": [{"text": "$decl a 1\n"}]}},
    {"method": "textDocument/didChange",
     "params": {"textDocument": {"uri": uri, "version": 3},
                "contentChanges": [{"text": "$decl a $call add (1, \n"}]}},
    {"method": "textDocument/didSave", "params": {"textDocument": {"uri": uri}}},
    {"id": 2, "method": "textDocument/hover", "params": {}},
    {"method": "textDocument/didClose", "params": {"textDocument": {"uri": uri}}},
    {"method": "textDocument/didOpen",
     "params": {"textDocument": {"uri": "file:///nonexistent/ws/big.mpl", "version": 1,
                                 "text": big}}},
    {"id": 3, "method": "shutdown"},
    {"method": "exit"},
]

out = sys.stdout.buffer
for i, m in enumerate(msgs):
    body = json.dumps(dict({"jsonrpc": "2.0"}, **m), ensure_ascii=False).encode()
    # Header names are case-insensitive; one message says so, and one carries a second
    # header the server must skip.
    head = b"content-length" if i == 1 else b"Content-Length"
    extra = b"Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n" if i == 2 else b""
    out.write(extra + head + b": %d\r\n\r\n" % len(body) + body)
    if i == 6:
        bad = b"{not json"
        out.write(b"Content-Length: %d\r\n\r\n" % len(bad) + bad)
