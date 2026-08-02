# Risu

Risu is a native Zig library for beautiful, lightweight, and composable
interactive CLI prompts.

The project is inspired by [Clack](https://github.com/bombshell-dev/clack). The
first MVP focuses on a small, testable core rather than terminal-specific
features: a prompt lifecycle state machine, injectable line input/output, and
one `TextPrompt` implementation.

## Requirements

- Zig master (the development build used during MVP development is
  `0.17.0-dev.1516+8a4b5424d`).
- No third-party Zig packages; the library only uses `zig std`.

## MVP core

`Prompt` owns the lifecycle (`idle -> active -> submitted` or
`idle -> active -> cancelled`). `Input` and `Output` are small type-erased
interfaces, so prompt logic can be tested without a real TTY or adapted to a
terminal frontend later. `TextPrompt.run()` returns an allocator-owned `[]u8`.

```zig
const std = @import("std");
const risu = @import("risu");

var lines = risu.LineInput.init(&.{.{ .line = "Ada" }});
var output = risu.BufferOutput.init(std.heap.page_allocator);
defer output.deinit();

var prompt = risu.TextPrompt.init(
    std.heap.page_allocator,
    lines.asInput(),
    output.asOutput(),
    .{ .message = "Your name?" },
);
const answer = try prompt.run();
defer std.heap.page_allocator.free(answer);
```

Validation callbacks return an optional error message. `initial_value` seeds
the editable input, while `default_value` is returned only when the submitted
value is empty. A future prompts layer can build select, confirm, spinner, and
terminal key handling on top of this core without changing the lifecycle
contract.

`AbortController` provides a Clack-style cancellation signal:

```zig
var controller = risu.AbortController.init();
var prompt = risu.TextPrompt.init(allocator, input, output, .{
    .message = "Your name?",
    .signal = controller.signal(),
});

controller.abort();
// prompt.run() or prompt.runKeys(...) returns error.Cancelled.
```

The synchronous input adapter checks the signal before rendering and before and
after each input read. A blocking adapter must return from its read operation
before the cancellation can be observed.

`TextPrompt.Options.render` 可以覆寫 default renderer。每次 prompt draw
會收到 `TextPrompt.RenderContext`，其中包含 `message`、`placeholder`、目前
`state`、`value`、`cursor` 與 validation error；renderer 只負責寫入注入的
`Output`。

除了 `run()` 的 line input，core 也提供 `KeyEvent` / `KeyInput` 與
`runKeys()`，目前支援 character、backspace、clear_line、delete_word、
word_left、word_right、delete_forward、home、end、kill_to_end、redraw、left、
right、enter、escape。
這層不解析 OS terminal escape sequence；terminal adapter 會在後續階段把
raw input 轉成這些事件。

## Runnable example

The repository also contains a small interactive application in
[`examples/basic.zig`](examples/basic.zig). It adapts Zig master
`std.Io.File.stdin/stdout` to the core interfaces, enters POSIX raw mode,
translates terminal bytes into `KeyEvent`, validates a name, and prints a
greeting:

```sh
zig build example
./zig-out/bin/risu-example
```

Type a name and try arrows, Alt/Option-arrows, Backspace, Ctrl-A/E/U/W/K/D/L, Enter, or Ctrl-C. The example is
intentionally a manual terminal check; its byte decoder and prompt flow are
also covered by deterministic tests in `zig build test`.

The example follows a Clack-style raw key-by-key model rather than Canonical
shell input. Common Unix editing controls are handled by the application:
Ctrl-C cancels, Ctrl-U clears the line, Ctrl-W deletes the previous word,
Ctrl-A/E move to the beginning/end, Ctrl-K deletes to the end, Ctrl-D deletes
forward or returns EOF on an empty line, and Ctrl-L redraws the prompt.

Alt/Option-Left and Alt/Option-Right move by ASCII-whitespace-delimited words.
The example accepts the common Meta encodings `ESC b` / `ESC f` (macOS Terminal
with Option-as-Meta and iTerm2's `+Esc` mode), xterm/VTE-style modified arrows
`CSI 1;3D` / `CSI 1;3C`, and an extra Meta prefix before a regular arrow
(`ESC ESC [D` / `ESC ESC [C`). This keeps the core `word_left` / `word_right`
events platform-neutral while allowing terminal adapters to support their local
key protocol.

The POSIX adapter decodes UTF-8 into Unicode code points, so cursor movement
and deletion never split a multi-byte character. A standalone Escape becomes
cancel after a 50 ms continuation timeout (rather than blocking forever while
waiting for a possible arrow-key sequence). It also observes `SIGWINCH` and
emits a `resize` event, causing the prompt to redraw while preserving its
value. The renderer uses `wcwidth` for its cursor cleanup, including wide
terminal characters.

For the same interactive flow without building first, run
`zig build run-example`.
Run it from an interactive TTY rather than piping or redirecting stdin; the
build step now forwards the terminal directly to the example. If the caller
does not provide a TTY, use the installed binary from the command above in a
terminal instead.

## Test

```sh
zig build test
```

## License

MIT
