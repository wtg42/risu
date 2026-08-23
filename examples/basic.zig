const std = @import("std");
const builtin = @import("builtin");
const risu = @import("risu");

const escape_timeout_ms = 50;
const resize_poll_ms = 100;

const NativeWidth = if (builtin.os.tag == .windows) struct {
    fn width(_: u21) usize {
        return 1;
    }
} else struct {
    extern "c" fn wcwidth(codepoint: c_uint) c_int;

    fn width(codepoint: u21) usize {
        const columns = wcwidth(@intCast(codepoint));
        // `wcwidth` reports -1 for a non-printable code point. KeyEvent only
        // carries valid Unicode scalars, but keeping a one-cell fallback makes
        // cursor cleanup robust for terminals with an incomplete locale table.
        return if (columns < 0) 1 else @intCast(columns);
    }
};

const ByteInput = struct {
    context: *anyopaque,
    read_fn: *const fn (context: *anyopaque) risu.Input.ReadError!u8,
    read_with_timeout_fn: *const fn (context: *anyopaque, timeout_ms: i32) risu.Input.ReadError!?u8,

    fn read(self: ByteInput) risu.Input.ReadError!u8 {
        return self.read_fn(self.context);
    }

    fn readWithTimeout(self: ByteInput, timeout_ms: i32) risu.Input.ReadError!?u8 {
        return self.read_with_timeout_fn(self.context, timeout_ms);
    }
};

const TerminalKeyInput = struct {
    bytes: ByteInput,

    pub fn init(bytes: ByteInput) TerminalKeyInput {
        return .{ .bytes = bytes };
    }

    pub fn asInput(self: *TerminalKeyInput) risu.KeyInput {
        return .{
            .context = self,
            .read_key_fn = readKey,
        };
    }

    fn readKey(context: *anyopaque, signal: ?risu.AbortSignal) risu.Input.ReadError!risu.KeyEvent {
        const self: *TerminalKeyInput = @ptrCast(@alignCast(context));
        while (true) {
            try checkCancelled(signal);
            if (ResizeWatcher.take()) return .resize;
            const byte = (try self.readByte(resize_poll_ms, signal)) orelse continue;

            if (byte == 0x1b) {
                if (try self.readEscape(signal)) |event| return event;
                continue;
            }

            if (decodeByte(byte)) |event| return event;
            if (byte >= 0x80) {
                if (try self.readUtf8(byte, signal)) |event| return event;
            }
            // Unbound control bytes are ignored, like an unhandled key in a
            // readline-style prompt. Actual stream errors still propagate.
        }
    }

    fn readByte(self: *TerminalKeyInput, timeout_ms: i32, signal: ?risu.AbortSignal) risu.Input.ReadError!?u8 {
        try checkCancelled(signal);
        const byte = try self.bytes.readWithTimeout(timeout_ms);
        try checkCancelled(signal);
        return byte;
    }

    fn readEscape(self: *TerminalKeyInput, signal: ?risu.AbortSignal) risu.Input.ReadError!?risu.KeyEvent {
        const next = (try self.readByte(escape_timeout_ms, signal)) orelse return .escape;
        return switch (next) {
            'b' => .word_left, // Meta-b: common in macOS Terminal and iTerm2.
            'f' => .word_right, // Meta-f: common in macOS Terminal and iTerm2.
            '[' => self.readCsi(signal),
            0x1b => self.readMetaPrefixedArrow(signal),
            else => null,
        };
    }

    /// Some terminals implement Option/Alt as an extra ESC prefix in front of
    /// their regular cursor-key sequence: ESC ESC [ D or ESC ESC [ C.
    fn readMetaPrefixedArrow(self: *TerminalKeyInput, signal: ?risu.AbortSignal) risu.Input.ReadError!?risu.KeyEvent {
        const next = (try self.readByte(escape_timeout_ms, signal)) orelse return .escape;
        if (next != '[') return null;
        const event = (try self.readCsi(signal)) orelse return null;
        return switch (event) {
            .left => .word_left,
            .right => .word_right,
            else => null,
        };
    }

    /// Decode both ordinary cursor keys (CSI D/C) and xterm-style modified
    /// cursor keys (CSI 1;3D/C, where modifier 3 means Alt/Meta).
    fn readCsi(self: *TerminalKeyInput, signal: ?risu.AbortSignal) risu.Input.ReadError!?risu.KeyEvent {
        var parameters: [16]u8 = undefined;
        var length: usize = 0;
        while (true) {
            const byte = (try self.readByte(escape_timeout_ms, signal)) orelse return .escape;
            if (byte >= 0x40 and byte <= 0x7e) {
                return decodeCsi(parameters[0..length], byte);
            }
            if (length == parameters.len) return null;
            parameters[length] = byte;
            length += 1;
        }
    }

    fn readUtf8(self: *TerminalKeyInput, first: u8, signal: ?risu.AbortSignal) risu.Input.ReadError!?risu.KeyEvent {
        const length = std.unicode.utf8ByteSequenceLength(first) catch return null;
        var bytes: [4]u8 = undefined;
        bytes[0] = first;
        var index: usize = 1;
        while (index < length) : (index += 1) {
            bytes[index] = (try self.readByte(escape_timeout_ms, signal)) orelse return null;
        }
        const codepoint = std.unicode.utf8Decode(bytes[0..length]) catch return null;
        return .{ .character = codepoint };
    }
};

fn checkCancelled(signal: ?risu.AbortSignal) risu.Input.ReadError!void {
    if (signal) |abort_signal| {
        if (abort_signal.isAborted()) return error.Cancelled;
    }
}

const ConsoleByteInput = if (builtin.os.tag == .windows) struct {
    reader: *std.Io.File.Reader,

    pub fn init(reader: *std.Io.File.Reader, _: std.Io.File) @This() {
        return .{ .reader = reader };
    }

    pub fn asInput(self: *@This()) ByteInput {
        return .{
            .context = self,
            .read_fn = read,
            .read_with_timeout_fn = readWithTimeout,
        };
    }

    fn read(context: *anyopaque) risu.Input.ReadError!u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const bytes = self.reader.interface.take(1) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfInput,
            error.ReadFailed => return error.ReadFailed,
        };
        return bytes[0];
    }

    fn readWithTimeout(context: *anyopaque, _: i32) risu.Input.ReadError!?u8 {
        return try read(context);
    }
} else struct {
    reader: *std.Io.File.Reader,
    handle: std.posix.fd_t,

    pub fn init(reader: *std.Io.File.Reader, file: std.Io.File) @This() {
        return .{ .reader = reader, .handle = file.handle };
    }

    pub fn asInput(self: *@This()) ByteInput {
        return .{
            .context = self,
            .read_fn = read,
            .read_with_timeout_fn = readWithTimeout,
        };
    }

    fn read(context: *anyopaque) risu.Input.ReadError!u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const bytes = self.reader.interface.take(1) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfInput,
            error.ReadFailed => return error.ReadFailed,
        };
        return bytes[0];
    }

    fn readWithTimeout(context: *anyopaque, timeout_ms: i32) risu.Input.ReadError!?u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.reader.interface.seek == self.reader.interface.end) {
            var fds = [_]std.posix.pollfd{.{
                .fd = self.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&fds, timeout_ms) catch return error.ReadFailed;
            if (ready == 0) return null;
        }
        return try read(context);
    }
};

const ResizeWatcher = if (builtin.os.tag == .windows) struct {
    const Registration = struct {
        pub fn deinit(_: *@This()) void {}
    };

    pub fn install() Registration {
        return .{};
    }

    pub fn take() bool {
        return false;
    }
} else struct {
    var pending = std.atomic.Value(bool).init(false);

    const Registration = struct {
        previous: std.posix.Sigaction,
        active: bool = true,

        pub fn deinit(self: *@This()) void {
            if (!self.active) return;
            std.posix.sigaction(.WINCH, &self.previous, null);
            self.active = false;
        }
    };

    pub fn install() Registration {
        pending.store(false, .release);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handle },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };
        var previous: std.posix.Sigaction = undefined;
        std.posix.sigaction(.WINCH, &action, &previous);
        return .{ .previous = previous };
    }

    pub fn take() bool {
        return pending.swap(false, .acq_rel);
    }

    fn handle(_: std.posix.SIG) callconv(.c) void {
        pending.store(true, .release);
    }
};

const ConsoleOutput = struct {
    writer: *std.Io.File.Writer,

    pub fn asOutput(self: *ConsoleOutput) risu.Output {
        return .{
            .context = self,
            .write_fn = write,
        };
    }

    fn write(context: *anyopaque, bytes: []const u8) risu.Output.WriteError!void {
        const self: *ConsoleOutput = @ptrCast(@alignCast(context));
        self.writer.interface.writeAll(bytes) catch return error.WriteFailed;
        self.writer.interface.flush() catch return error.WriteFailed;
    }

    fn writeText(self: *ConsoleOutput, bytes: []const u8) !void {
        try self.writer.interface.writeAll(bytes);
        try self.writer.interface.flush();
    }
};

const ConsoleCapabilities = if (builtin.os.tag == .windows) struct {
    pub fn init(_: std.Io.File) @This() {
        return .{};
    }

    pub fn asCapabilities(self: *@This()) risu.TerminalCapabilities {
        return .{
            .context = self,
            .size_fn = size,
            .display_width_fn = displayWidth,
        };
    }

    fn size(_: *anyopaque) risu.TerminalSize {
        return .{ .columns = 80, .rows = 25 };
    }

    fn displayWidth(_: *anyopaque, codepoint: u21) usize {
        return NativeWidth.width(codepoint);
    }
} else struct {
    file: std.Io.File,

    pub fn init(file: std.Io.File) @This() {
        return .{ .file = file };
    }

    pub fn asCapabilities(self: *@This()) risu.TerminalCapabilities {
        return .{
            .context = self,
            .size_fn = size,
            .display_width_fn = displayWidth,
        };
    }

    fn size(context: *anyopaque) risu.TerminalSize {
        const self: *@This() = @ptrCast(@alignCast(context));
        var window_size: std.posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };
        const request: c_int = @bitCast(@as(c_uint, @intCast(std.posix.T.IOCGWINSZ)));
        if (std.posix.system.ioctl(self.file.handle, request, &window_size) < 0) {
            return .{ .columns = 80, .rows = 25 };
        }
        return .{
            .columns = if (window_size.col == 0) 80 else window_size.col,
            .rows = if (window_size.row == 0) 25 else window_size.row,
        };
    }

    fn displayWidth(_: *anyopaque, codepoint: u21) usize {
        return NativeWidth.width(codepoint);
    }
};

/// POSIX raw mode is deliberately kept in the example adapter. The core only
/// consumes platform-neutral KeyEvent values.
const RawTerminal = if (builtin.os.tag == .windows) struct {
    pub fn enter(_: std.Io.File) !@This() {
        return error.Unsupported;
    }

    pub fn deinit(_: *@This()) void {}
} else struct {
    handle: std.posix.fd_t,
    original: std.posix.termios,
    resize: ResizeWatcher.Registration,
    active: bool = true,

    pub fn enter(file: std.Io.File) !@This() {
        const original = try std.posix.tcgetattr(file.handle);
        var raw = original;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@backingInt(std.c.V.MIN)] = 1;
        raw.cc[@backingInt(std.c.V.TIME)] = 0;
        try std.posix.tcsetattr(file.handle, .NOW, raw);
        return .{
            .handle = file.handle,
            .original = original,
            .resize = ResizeWatcher.install(),
        };
    }

    pub fn deinit(self: *@This()) void {
        if (!self.active) return;
        std.posix.tcsetattr(self.handle, .NOW, self.original) catch {};
        self.resize.deinit();
        self.active = false;
    }
};

fn decodeByte(byte: u8) ?risu.KeyEvent {
    return switch (byte) {
        '\r', '\n' => .enter,
        0x03 => .escape, // Ctrl-C is the reliable cancel key in raw mode.
        0x04 => .delete_forward, // Ctrl-D: forward delete or EOF on empty input.
        0x15 => .clear_line, // Ctrl-U is the conventional Unix line-kill key.
        0x17 => .delete_word, // Ctrl-W deletes the previous word.
        0x01 => .home, // Ctrl-A moves to the beginning of the line.
        0x05 => .end, // Ctrl-E moves to the end of the line.
        0x0b => .kill_to_end, // Ctrl-K deletes to the end of the line.
        0x0c => .redraw, // Ctrl-L requests a prompt redraw.
        0x08, 0x7f => .backspace,
        0x20...0x7e => .{ .character = byte },
        else => null,
    };
}

fn decodeCsi(parameters: []const u8, final: u8) ?risu.KeyEvent {
    const alt = std.mem.eql(u8, parameters, "1;3");
    return switch (final) {
        'C' => if (alt) .word_right else if (parameters.len == 0) .right else null,
        'D' => if (alt) .word_left else if (parameters.len == 0) .left else null,
        else => null,
    };
}

fn validateName(value: []const u8) ?[]const u8 {
    if (value.len < 2) return "Please use at least two characters.";
    return null;
}

fn renderPrompt(output: risu.Output, view: risu.TextPrompt.RenderContext) risu.Output.WriteError!void {
    const prefix = switch (view.state) {
        .submitted => "done ",
        .cancelled => "cancelled ",
        else => "? ",
    };
    try output.write(prefix);
    try output.write(view.message);
    const displayed_value = view.submitted_value orelse view.value;
    if (displayed_value.len > 0) {
        try output.write(" ");
        if (view.state == .active) {
            try renderInputWithCursor(output, view.value, view.cursor);
        } else {
            try output.write(displayed_value);
        }
    } else if (view.state == .active) if (view.placeholder) |placeholder| {
        try output.write(" [");
        try output.write(placeholder);
        try output.write("]");
    };

    if (view.validation_error) |message| {
        try output.write("\nerror: ");
        try output.write(message);
    }
}

fn renderInputWithCursor(output: risu.Output, value: []const u8, cursor: usize) risu.Output.WriteError!void {
    try output.write(value[0..cursor]);
    try output.write("\x1b[7m");
    if (cursor < value.len) {
        const width = std.unicode.utf8ByteSequenceLength(value[cursor]) catch 1;
        const end = @min(cursor + width, value.len);
        try output.write(value[cursor..end]);
        try output.write("\x1b[27m");
        try output.write(value[end..]);
    } else {
        try output.write(" ");
        try output.write("\x1b[27m");
    }
}

pub fn runPrompt(allocator: std.mem.Allocator, input: risu.KeyInput, output: risu.Output) risu.TextPrompt.RunError![]u8 {
    var prompt = risu.TextPrompt.init(allocator, null, output, .{
        .message = "What is your name?",
        .placeholder = "Ada",
        .validate = validateName,
        .render = renderPrompt,
    });
    return prompt.runKeys(input);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var io_instance: std.Io.Threaded = .init(allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    const stdin_file = std.Io.File.stdin();
    const stdout_file = std.Io.File.stdout();
    var input_buffer: [4096]u8 = undefined;
    var file_reader = stdin_file.readerStreaming(io, &input_buffer);
    var byte_input = ConsoleByteInput.init(&file_reader, stdin_file);
    var input = TerminalKeyInput.init(byte_input.asInput());
    var output_buffer: [4096]u8 = undefined;
    var file_writer = stdout_file.writerStreaming(io, &output_buffer);
    var output = ConsoleOutput{ .writer = &file_writer };
    var capabilities = ConsoleCapabilities.init(stdout_file);
    var framed_output = risu.TerminalFrameOutput.init(
        allocator,
        output.asOutput(),
        capabilities.asCapabilities(),
    );
    defer framed_output.deinit();

    try output.writeText("TextPrompt key-event demo\n");
    try output.writeText("Use arrows, Alt/Option-arrows, Backspace, Ctrl-A/E/U/W/K/D/L, Enter, or Ctrl-C.\n");

    var terminal = try RawTerminal.enter(stdin_file);
    defer terminal.deinit();

    const answer = runPrompt(allocator, input.asInput(), framed_output.asOutput()) catch |err| switch (err) {
        error.Cancelled => {
            framed_output.deinit();
            terminal.deinit();
            try output.writeText("\nCancelled.\n");
            return;
        },
        error.EndOfInput => {
            framed_output.deinit();
            terminal.deinit();
            try output.writeText("\nNo input received.\n");
            return;
        },
        else => return err,
    };
    defer allocator.free(answer);

    framed_output.deinit();
    terminal.deinit();
    try output.writeText("\nHello, ");
    try output.writeText(answer);
    try output.writeText("!\n");
}

test "example app uses the risu key-event prompt" {
    var input = risu.KeyInputSequence.init(&.{
        .{ .character = 'A' },
        .{ .character = 'd' },
        .{ .character = 'a' },
        .enter,
    });
    var output = risu.BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    const answer = try runPrompt(std.testing.allocator, input.asInput(), output.asOutput());
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("Ada", answer);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "What is your name?") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "done What is your name? Ada") != null);
}

const FixedTestCapabilities = struct {
    fn asCapabilities(self: *FixedTestCapabilities) risu.TerminalCapabilities {
        return .{
            .context = self,
            .size_fn = size,
            .display_width_fn = width,
        };
    }

    fn size(_: *anyopaque) risu.TerminalSize {
        return .{ .columns = 80, .rows = 20 };
    }

    fn width(_: *anyopaque, _: u21) usize {
        return 1;
    }
};

test "example prompt renders through terminal frame output and restores the cursor" {
    var input = risu.KeyInputSequence.init(&.{
        .{ .character = 'A' },
        .{ .character = 'd' },
        .{ .character = 'a' },
        .enter,
    });
    var destination = risu.BufferOutput.init(std.testing.allocator);
    defer destination.deinit();
    var capabilities = FixedTestCapabilities{};
    var framed_output = risu.TerminalFrameOutput.init(
        std.testing.allocator,
        destination.asOutput(),
        capabilities.asCapabilities(),
    );
    defer framed_output.deinit();

    const answer = try runPrompt(std.testing.allocator, input.asInput(), framed_output.asOutput());
    defer std.testing.allocator.free(answer);
    framed_output.deinit();

    try std.testing.expect(std.mem.startsWith(u8, destination.items(), "\x1b[?25l"));
    try std.testing.expect(std.mem.indexOf(u8, destination.items(), "done What is your name? Ada") != null);
    try std.testing.expect(std.mem.endsWith(u8, destination.items(), "\x1b[?25h"));
    try std.testing.expect(std.mem.indexOf(u8, destination.items(), "\x1b[D") == null);
}

test "example prompt renders a final cancelled frame" {
    var input = risu.KeyInputSequence.init(&.{
        .{ .character = 'x' },
        .escape,
    });
    var output = risu.BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(
        error.Cancelled,
        runPrompt(std.testing.allocator, input.asInput(), output.asOutput()),
    );
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "cancelled What is your name? x") != null);
}

test "console key decoder maps terminal bytes" {
    try std.testing.expectEqual(risu.KeyEvent.enter, decodeByte('\r').?);
    try std.testing.expectEqual(risu.KeyEvent.enter, decodeByte('\n').?);
    try std.testing.expectEqual(risu.KeyEvent.backspace, decodeByte(0x7f).?);
    try std.testing.expectEqual(risu.KeyEvent.home, decodeByte(0x01).?);
    try std.testing.expectEqual(risu.KeyEvent.delete_forward, decodeByte(0x04).?);
    try std.testing.expectEqual(risu.KeyEvent.end, decodeByte(0x05).?);
    try std.testing.expectEqual(risu.KeyEvent.kill_to_end, decodeByte(0x0b).?);
    try std.testing.expectEqual(risu.KeyEvent.redraw, decodeByte(0x0c).?);
    try std.testing.expectEqual(risu.KeyEvent.clear_line, decodeByte(0x15).?);
    try std.testing.expectEqual(risu.KeyEvent.delete_word, decodeByte(0x17).?);
    try std.testing.expectEqual(risu.KeyEvent.escape, decodeByte(0x03).?);
    try std.testing.expectEqual(@as(?risu.KeyEvent, null), decodeByte(0x1a));
    try std.testing.expectEqual(risu.KeyEvent.left, decodeCsi("", 'D').?);
    try std.testing.expectEqual(risu.KeyEvent.right, decodeCsi("", 'C').?);
    try std.testing.expectEqual(@as(u21, 'A'), decodeByte('A').?.character);
}

const TestByteInput = struct {
    bytes: []const u8,
    index: usize = 0,

    fn init(bytes: []const u8) TestByteInput {
        return .{ .bytes = bytes };
    }

    fn asInput(self: *TestByteInput) ByteInput {
        return .{
            .context = self,
            .read_fn = read,
            .read_with_timeout_fn = readWithTimeout,
        };
    }

    fn read(context: *anyopaque) risu.Input.ReadError!u8 {
        const self: *TestByteInput = @ptrCast(@alignCast(context));
        if (self.index == self.bytes.len) return error.EndOfInput;
        defer self.index += 1;
        return self.bytes[self.index];
    }

    fn readWithTimeout(context: *anyopaque, _: i32) risu.Input.ReadError!?u8 {
        const self: *TestByteInput = @ptrCast(@alignCast(context));
        if (self.index == self.bytes.len) return null;
        return try read(self);
    }
};

const AbortOnTimeoutByteInput = struct {
    controller: *risu.AbortController,

    fn asInput(self: *AbortOnTimeoutByteInput) ByteInput {
        return .{
            .context = self,
            .read_fn = read,
            .read_with_timeout_fn = readWithTimeout,
        };
    }

    fn read(_: *anyopaque) risu.Input.ReadError!u8 {
        return error.EndOfInput;
    }

    fn readWithTimeout(context: *anyopaque, _: i32) risu.Input.ReadError!?u8 {
        const self: *AbortOnTimeoutByteInput = @ptrCast(@alignCast(context));
        self.controller.abort();
        return null;
    }
};

test "terminal key input observes aborts during bounded waits" {
    var controller = risu.AbortController.init();
    var byte_input = AbortOnTimeoutByteInput{ .controller = &controller };
    var keys = TerminalKeyInput.init(byte_input.asInput());

    try std.testing.expectError(
        error.Cancelled,
        keys.asInput().readKey(controller.signal()),
    );
}

test "terminal key decoder handles UTF-8 and an escape timeout" {
    var unicode_bytes = TestByteInput.init("界");
    var unicode_keys = TerminalKeyInput.init(unicode_bytes.asInput());
    const unicode_event = try unicode_keys.asInput().readKey(null);
    try std.testing.expectEqual(@as(u21, '界'), unicode_event.character);

    var escape_bytes = TestByteInput.init(&.{0x1b});
    var escape_keys = TerminalKeyInput.init(escape_bytes.asInput());
    try std.testing.expectEqual(risu.KeyEvent.escape, try escape_keys.asInput().readKey(null));

    var arrow_bytes = TestByteInput.init("\x1b[D");
    var arrow_keys = TerminalKeyInput.init(arrow_bytes.asInput());
    try std.testing.expectEqual(risu.KeyEvent.left, try arrow_keys.asInput().readKey(null));
}

test "terminal key decoder maps common Alt or Option arrow encodings" {
    const Case = struct {
        bytes: []const u8,
        expected: risu.KeyEvent,
    };
    const cases = [_]Case{
        .{ .bytes = "\x1bb", .expected = .word_left }, // macOS Meta + Left.
        .{ .bytes = "\x1bf", .expected = .word_right }, // macOS Meta + Right.
        .{ .bytes = "\x1b[1;3D", .expected = .word_left }, // xterm/VTE Alt + Left.
        .{ .bytes = "\x1b[1;3C", .expected = .word_right }, // xterm/VTE Alt + Right.
        .{ .bytes = "\x1b\x1b[D", .expected = .word_left }, // Meta prefix plus normal arrow.
        .{ .bytes = "\x1b\x1b[C", .expected = .word_right },
    };

    for (cases) |case| {
        var byte_input = TestByteInput.init(case.bytes);
        var keys = TerminalKeyInput.init(byte_input.asInput());
        try std.testing.expectEqual(case.expected, try keys.asInput().readKey(null));
    }
}
