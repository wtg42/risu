//! Risu is a native Zig library for composable interactive CLI prompts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("terminal.zig");

/// Current terminal dimensions in character cells.
pub const TerminalSize = terminal.TerminalSize;
/// Injected terminal dimensions and Unicode display-width policy.
pub const TerminalCapabilities = terminal.TerminalCapabilities;
/// An output adapter that atomically wraps and replaces rendered frames.
pub const TerminalFrameOutput = terminal.FrameOutput(Output);

pub const PromptState = enum {
    idle,
    active,
    submitted,
    cancelled,
};

pub const PromptError = error{
    AlreadyStarted,
    InvalidState,
};

/// The smallest lifecycle primitive shared by all prompt implementations.
///
/// A prompt is deliberately independent from terminal details. Prompt
/// implementations can use this state machine with any injected input and
/// output backend.
pub const Prompt = struct {
    message: []const u8,
    state_value: PromptState = .idle,

    pub fn init(message: []const u8) Prompt {
        return .{ .message = message };
    }

    pub fn state(self: *const Prompt) PromptState {
        return self.state_value;
    }

    pub fn begin(self: *Prompt) PromptError!void {
        if (self.state_value != .idle) return error.AlreadyStarted;
        self.state_value = .active;
    }

    pub fn submit(self: *Prompt) PromptError!void {
        if (self.state_value != .active) return error.InvalidState;
        self.state_value = .submitted;
    }

    pub fn cancel(self: *Prompt) PromptError!void {
        if (self.state_value != .active) return error.InvalidState;
        self.state_value = .cancelled;
    }
};

/// Input is an intentionally small type-erased line source. A terminal,
/// scripted test, or another application can provide its own implementation.
/// Blocking implementations must wake or use bounded waits to observe the
/// optional abort signal passed to `readLine`.
pub const Input = struct {
    pub const ReadError = error{
        EndOfInput,
        Cancelled,
        ReadFailed,
    };

    context: *anyopaque,
    read_line_fn: *const fn (context: *anyopaque, signal: ?AbortSignal) ReadError![]const u8,

    pub fn readLine(self: Input, signal: ?AbortSignal) ReadError![]const u8 {
        return self.read_line_fn(self.context, signal);
    }
};

/// A type-erased cancellation probe for prompt execution.
///
/// Prompt input adapters remain synchronous. A prompt checks the signal around
/// rendering and input, and passes it into reads so blocking adapters can wake
/// or poll for cancellation.
pub const AbortSignal = struct {
    context: *const anyopaque,
    is_aborted_fn: *const fn (context: *const anyopaque) bool,

    pub fn isAborted(self: AbortSignal) bool {
        return self.is_aborted_fn(self.context);
    }
};

/// A thread-safe controller for an `AbortSignal`.
pub const AbortController = struct {
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init() AbortController {
        return .{};
    }

    pub fn abort(self: *AbortController) void {
        self.aborted.store(true, .release);
    }

    pub fn signal(self: *const AbortController) AbortSignal {
        return .{
            .context = self,
            .is_aborted_fn = isAborted,
        };
    }

    fn isAborted(context: *const anyopaque) bool {
        const self: *const AbortController = @ptrCast(@alignCast(context));
        return self.aborted.load(.acquire);
    }
};

/// A deterministic input source useful for tests and examples.
pub const LineInput = struct {
    pub const Event = union(enum) {
        line: []const u8,
        cancel: void,
    };

    events: []const Event,
    index: usize = 0,

    pub fn init(events: []const Event) LineInput {
        return .{ .events = events };
    }

    pub fn asInput(self: *LineInput) Input {
        return .{
            .context = self,
            .read_line_fn = readLine,
        };
    }

    fn readLine(context: *anyopaque, signal: ?AbortSignal) Input.ReadError![]const u8 {
        const self: *LineInput = @ptrCast(@alignCast(context));
        if (signal) |abort_signal| {
            if (abort_signal.isAborted()) return error.Cancelled;
        }
        if (self.index >= self.events.len) return error.EndOfInput;

        const event = self.events[self.index];
        self.index += 1;
        return switch (event) {
            .line => |line| line,
            .cancel => error.Cancelled,
        };
    }
};

/// A small, platform-neutral key vocabulary for interactive prompts.
///
/// This is intentionally independent from terminal escape sequences. A
/// terminal adapter can translate raw bytes into these events later.
pub const KeyEvent = union(enum) {
    character: u21,
    backspace,
    clear_line,
    delete_word,
    word_left,
    word_right,
    delete_forward,
    home,
    end,
    kill_to_end,
    redraw,
    resize,
    left,
    right,
    enter,
    escape,
};

/// Type-erased key-event input for interactive prompt implementations.
/// Blocking implementations follow the same cancellation contract as `Input`.
pub const KeyInput = struct {
    context: *anyopaque,
    read_key_fn: *const fn (context: *anyopaque, signal: ?AbortSignal) Input.ReadError!KeyEvent,

    pub fn readKey(self: KeyInput, signal: ?AbortSignal) Input.ReadError!KeyEvent {
        return self.read_key_fn(self.context, signal);
    }
};

/// Deterministic key events for tests and examples.
pub const KeyInputSequence = struct {
    events: []const KeyEvent,
    index: usize = 0,

    pub fn init(events: []const KeyEvent) KeyInputSequence {
        return .{ .events = events };
    }

    pub fn asInput(self: *KeyInputSequence) KeyInput {
        return .{
            .context = self,
            .read_key_fn = readKey,
        };
    }

    fn readKey(context: *anyopaque, signal: ?AbortSignal) Input.ReadError!KeyEvent {
        const self: *KeyInputSequence = @ptrCast(@alignCast(context));
        if (signal) |abort_signal| {
            if (abort_signal.isAborted()) return error.Cancelled;
        }
        if (self.index >= self.events.len) return error.EndOfInput;

        const event = self.events[self.index];
        self.index += 1;
        return event;
    }
};

/// Output is also type-erased so core logic is testable without a real TTY.
/// Optional frame callbacks let an adapter buffer and atomically commit or
/// discard all writes made by one renderer invocation.
pub const Output = struct {
    pub const WriteError = error{WriteFailed};

    context: *anyopaque,
    write_fn: *const fn (context: *anyopaque, bytes: []const u8) WriteError!void,
    begin_frame_fn: ?*const fn (context: *anyopaque) WriteError!void = null,
    finish_frame_fn: ?*const fn (context: *anyopaque, commit: bool) WriteError!void = null,

    pub fn write(self: Output, bytes: []const u8) WriteError!void {
        return self.write_fn(self.context, bytes);
    }

    pub fn beginFrame(self: Output) WriteError!void {
        if (self.begin_frame_fn) |begin_frame| {
            try begin_frame(self.context);
        }
    }

    pub fn finishFrame(self: Output, commit: bool) WriteError!void {
        if (self.finish_frame_fn) |finish_frame| {
            try finish_frame(self.context, commit);
        }
    }
};

/// An in-memory output sink for deterministic tests and captured transcripts.
pub const BufferOutput = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8) = .empty,

    pub fn init(allocator: Allocator) BufferOutput {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BufferOutput) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn items(self: *const BufferOutput) []const u8 {
        return self.buffer.items;
    }

    pub fn asOutput(self: *BufferOutput) Output {
        return .{
            .context = self,
            .write_fn = write,
        };
    }

    fn write(context: *anyopaque, bytes: []const u8) Output.WriteError!void {
        const self: *BufferOutput = @ptrCast(@alignCast(context));
        self.buffer.appendSlice(self.allocator, bytes) catch return error.WriteFailed;
    }
};

pub const TextPrompt = struct {
    pub const Validator = *const fn (value: []const u8) ?[]const u8;

    /// The immutable view passed to a custom renderer for each prompt draw.
    pub const RenderContext = struct {
        message: []const u8,
        placeholder: ?[]const u8,
        state: PromptState,
        validation_error: ?[]const u8,
        value: []const u8,
        /// Resolved result for the submitted frame; otherwise null.
        submitted_value: ?[]const u8,
        /// Byte offset into `value`, always maintained at a UTF-8 code point boundary.
        cursor: usize,
    };

    pub const Renderer = *const fn (output: Output, view: RenderContext) Output.WriteError!void;

    pub const Options = struct {
        message: []const u8,
        placeholder: ?[]const u8 = null,
        initial_value: ?[]const u8 = null,
        default_value: ?[]const u8 = null,
        validate: ?Validator = null,
        render: ?Renderer = null,
        signal: ?AbortSignal = null,
    };

    pub const RunError = error{
        AlreadyStarted,
        InvalidState,
        Cancelled,
        EndOfInput,
        InputFailed,
        OutputFailed,
        OutOfMemory,
    };

    allocator: Allocator,
    input: ?Input,
    output: Output,
    options: Options,
    lifecycle: Prompt,
    validation_error: ?[]const u8 = null,

    pub fn init(allocator: Allocator, input: ?Input, output: Output, options: Options) TextPrompt {
        return .{
            .allocator = allocator,
            .input = input,
            .output = output,
            .options = options,
            .lifecycle = Prompt.init(options.message),
        };
    }

    pub fn state(self: *const TextPrompt) PromptState {
        return self.lifecycle.state();
    }

    /// Run a line-oriented text prompt and return an allocator-owned answer.
    ///
    /// `initial_value` is rendered as the initial editable value. An empty
    /// submitted line is validated before it uses `default_value` when one is
    /// configured; it does not fall back to `initial_value`. Validation errors
    /// preserve the rejected line, and terminal states receive a final frame.
    pub fn run(self: *TextPrompt) RunError![]u8 {
        self.lifecycle.begin() catch return error.AlreadyStarted;
        if (self.isAborted()) {
            self.markCancelled();
            return error.Cancelled;
        }
        const input = self.input orelse {
            self.markCancelled();
            return error.InputFailed;
        };
        const initial = self.options.initial_value orelse &.{};
        var rendered_value = initial;
        self.renderPrompt(initial, initial.len, null) catch {
            self.markCancelled();
            return error.OutputFailed;
        };

        while (true) {
            if (self.isAborted()) {
                try self.cancelAndRender(rendered_value, rendered_value.len);
                return error.Cancelled;
            }
            const line = input.readLine(self.options.signal) catch |err| switch (err) {
                error.Cancelled => {
                    try self.cancelAndRender(rendered_value, rendered_value.len);
                    return error.Cancelled;
                },
                error.EndOfInput => {
                    try self.cancelAndRender(rendered_value, rendered_value.len);
                    return error.EndOfInput;
                },
                error.ReadFailed => {
                    try self.cancelAndRender(rendered_value, rendered_value.len);
                    return error.InputFailed;
                },
            };
            rendered_value = line;
            if (self.isAborted()) {
                try self.cancelAndRender(line, line.len);
                return error.Cancelled;
            }

            if (self.options.validate) |validate| {
                if (validate(line)) |message| {
                    self.validation_error = message;
                    self.renderPrompt(line, line.len, null) catch {
                        self.markCancelled();
                        return error.OutputFailed;
                    };
                    self.validation_error = null;
                    continue;
                }
            }

            const value = self.valueOrDefault(line);
            const answer = self.allocator.dupe(u8, value) catch {
                self.markCancelled();
                return error.OutOfMemory;
            };
            self.lifecycle.submit() catch {
                self.allocator.free(answer);
                self.markCancelled();
                return error.InvalidState;
            };
            self.renderPrompt(line, line.len, answer) catch {
                self.allocator.free(answer);
                return error.OutputFailed;
            };
            return answer;
        }
    }

    /// Run the prompt from a platform-neutral stream of key events.
    ///
    /// A terminal adapter is responsible for translating escape sequences into
    /// `KeyEvent`; this method only owns UTF-8-safe editing, validation,
    /// rendering requests, and lifecycle. Validation precedes default
    /// resolution, and submitted or cancelled states receive a final frame.
    pub fn runKeys(self: *TextPrompt, key_input: KeyInput) RunError![]u8 {
        self.lifecycle.begin() catch return error.AlreadyStarted;
        if (self.isAborted()) {
            self.markCancelled();
            return error.Cancelled;
        }

        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(self.allocator);
        var cursor: usize = 0;

        if (self.options.initial_value) |initial| {
            if (!std.unicode.utf8ValidateSlice(initial)) {
                self.markCancelled();
                return error.InputFailed;
            }
            value.appendSlice(self.allocator, initial) catch {
                self.markCancelled();
                return error.OutOfMemory;
            };
            cursor = value.items.len;
        }

        self.renderPrompt(value.items, cursor, null) catch {
            self.markCancelled();
            return error.OutputFailed;
        };

        while (true) {
            if (self.isAborted()) {
                try self.cancelAndRender(value.items, cursor);
                return error.Cancelled;
            }
            const event = key_input.readKey(self.options.signal) catch |err| switch (err) {
                error.Cancelled => {
                    try self.cancelAndRender(value.items, cursor);
                    return error.Cancelled;
                },
                error.EndOfInput => {
                    try self.cancelAndRender(value.items, cursor);
                    return error.EndOfInput;
                },
                error.ReadFailed => {
                    try self.cancelAndRender(value.items, cursor);
                    return error.InputFailed;
                },
            };
            if (self.isAborted()) {
                try self.cancelAndRender(value.items, cursor);
                return error.Cancelled;
            }

            switch (event) {
                .character => |character| {
                    var encoded: [4]u8 = undefined;
                    const encoded_len = std.unicode.utf8Encode(character, &encoded) catch {
                        self.markCancelled();
                        return error.InputFailed;
                    };
                    value.insertSlice(self.allocator, cursor, encoded[0..encoded_len]) catch {
                        self.markCancelled();
                        return error.OutOfMemory;
                    };
                    cursor += encoded_len;
                },
                .backspace => {
                    if (cursor > 0) {
                        const start = previousCodepointStart(value.items, cursor);
                        value.replaceRangeAssumeCapacity(start, cursor - start, &.{});
                        cursor = start;
                    }
                },
                .clear_line => {
                    value.clearRetainingCapacity();
                    cursor = 0;
                },
                .delete_word => {
                    while (cursor > 0 and isWhitespaceBefore(value.items, cursor)) {
                        const start = previousCodepointStart(value.items, cursor);
                        value.replaceRangeAssumeCapacity(start, cursor - start, &.{});
                        cursor = start;
                    }
                    while (cursor > 0 and !isWhitespaceBefore(value.items, cursor)) {
                        const start = previousCodepointStart(value.items, cursor);
                        value.replaceRangeAssumeCapacity(start, cursor - start, &.{});
                        cursor = start;
                    }
                },
                .word_left => {
                    while (cursor > 0 and isWhitespaceBefore(value.items, cursor)) {
                        cursor = previousCodepointStart(value.items, cursor);
                    }
                    while (cursor > 0 and !isWhitespaceBefore(value.items, cursor)) {
                        cursor = previousCodepointStart(value.items, cursor);
                    }
                },
                .word_right => {
                    while (cursor < value.items.len and isWhitespaceAt(value.items, cursor)) {
                        cursor = nextCodepointEnd(value.items, cursor);
                    }
                    while (cursor < value.items.len and !isWhitespaceAt(value.items, cursor)) {
                        cursor = nextCodepointEnd(value.items, cursor);
                    }
                },
                .delete_forward => {
                    if (value.items.len == 0) {
                        try self.cancelAndRender(value.items, cursor);
                        return error.EndOfInput;
                    }
                    if (cursor < value.items.len) {
                        const end = nextCodepointEnd(value.items, cursor);
                        value.replaceRangeAssumeCapacity(cursor, end - cursor, &.{});
                    }
                },
                .home => cursor = 0,
                .end => cursor = value.items.len,
                .kill_to_end => value.shrinkRetainingCapacity(cursor),
                .redraw => {},
                .resize => {},
                .left => {
                    if (cursor > 0) cursor = previousCodepointStart(value.items, cursor);
                },
                .right => {
                    if (cursor < value.items.len) cursor = nextCodepointEnd(value.items, cursor);
                },
                .escape => {
                    try self.cancelAndRender(value.items, cursor);
                    return error.Cancelled;
                },
                .enter => {
                    if (self.options.validate) |validate| {
                        if (validate(value.items)) |message| {
                            self.validation_error = message;
                            self.renderPrompt(value.items, cursor, null) catch {
                                self.markCancelled();
                                return error.OutputFailed;
                            };
                            self.validation_error = null;
                            continue;
                        }
                    }

                    const candidate = self.valueOrDefault(value.items);
                    const answer = self.allocator.dupe(u8, candidate) catch {
                        self.markCancelled();
                        return error.OutOfMemory;
                    };
                    self.lifecycle.submit() catch {
                        self.allocator.free(answer);
                        self.markCancelled();
                        return error.InvalidState;
                    };
                    self.renderPrompt(value.items, cursor, answer) catch {
                        self.allocator.free(answer);
                        return error.OutputFailed;
                    };
                    return answer;
                },
            }

            self.renderPrompt(value.items, cursor, null) catch {
                self.markCancelled();
                return error.OutputFailed;
            };
        }
    }

    fn renderPrompt(
        self: *TextPrompt,
        value: []const u8,
        cursor: usize,
        submitted_value: ?[]const u8,
    ) Output.WriteError!void {
        const view: RenderContext = .{
            .message = self.options.message,
            .placeholder = self.options.placeholder,
            .state = self.lifecycle.state(),
            .validation_error = self.validation_error,
            .value = value,
            .submitted_value = submitted_value,
            .cursor = cursor,
        };
        try self.output.beginFrame();
        self.renderFrame(view) catch |err| {
            self.output.finishFrame(false) catch {};
            return err;
        };
        try self.output.finishFrame(true);
    }

    fn renderFrame(self: *TextPrompt, view: RenderContext) Output.WriteError!void {
        if (self.options.render) |render| return render(self.output, view);

        if (view.validation_error) |message| {
            try self.output.write("\nerror: ");
            try self.output.write(message);
            try self.output.write("\n");
        }
        try self.output.write(view.message);
        const displayed_value = view.submitted_value orelse view.value;
        if (displayed_value.len > 0) {
            try self.output.write(" ");
            try self.output.write(displayed_value);
        } else if (view.state == .active) if (view.placeholder) |placeholder| {
            try self.output.write(" [");
            try self.output.write(placeholder);
            try self.output.write("]");
        };
        try self.output.write(" ");
    }

    fn valueOrDefault(self: *const TextPrompt, value: []const u8) []const u8 {
        if (value.len == 0) return self.options.default_value orelse value;
        return value;
    }

    fn isAborted(self: *const TextPrompt) bool {
        if (self.options.signal) |signal| return signal.isAborted();
        return false;
    }

    fn previousCodepointStart(value: []const u8, cursor: usize) usize {
        var index = cursor;
        while (index > 0) {
            index -= 1;
            if (value[index] & 0b1100_0000 != 0b1000_0000) return index;
        }
        return 0;
    }

    fn nextCodepointEnd(value: []const u8, cursor: usize) usize {
        if (cursor >= value.len) return value.len;
        const width = std.unicode.utf8ByteSequenceLength(value[cursor]) catch return cursor + 1;
        const end = cursor + width;
        return if (end <= value.len) end else cursor + 1;
    }

    fn isWhitespaceBefore(value: []const u8, cursor: usize) bool {
        const start = previousCodepointStart(value, cursor);
        return start + 1 == cursor and std.ascii.isWhitespace(value[start]);
    }

    fn isWhitespaceAt(value: []const u8, cursor: usize) bool {
        const end = nextCodepointEnd(value, cursor);
        return end == cursor + 1 and std.ascii.isWhitespace(value[cursor]);
    }

    fn markCancelled(self: *TextPrompt) void {
        if (self.lifecycle.state() == .active) {
            self.lifecycle.cancel() catch {};
        }
    }

    fn cancelAndRender(self: *TextPrompt, value: []const u8, cursor: usize) RunError!void {
        self.markCancelled();
        self.renderPrompt(value, cursor, null) catch return error.OutputFailed;
    }
};

test "text prompt returns an entered line" {
    var input = LineInput.init(&.{.{ .line = "Ada" }});
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Your name?",
    });

    const answer = try prompt.run();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("Ada", answer);
    try std.testing.expectEqual(PromptState.submitted, prompt.state());
    try std.testing.expectEqualStrings("Your name? Your name? Ada ", output.items());
}

fn atLeastTwoCharacters(value: []const u8) ?[]const u8 {
    if (value.len < 2) return "Use at least two characters.";
    return null;
}

test "text prompt retries validation errors and renders each attempt" {
    var input = LineInput.init(&.{
        .{ .line = "A" },
        .{ .line = "Ada" },
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Your name?",
        .validate = atLeastTwoCharacters,
    });

    const answer = try prompt.run();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("Ada", answer);
    try std.testing.expectEqualStrings(
        "Your name? \nerror: Use at least two characters.\nYour name? A Your name? Ada ",
        output.items(),
    );
}

test "empty line input does not use the initial value as a fallback" {
    var input = LineInput.init(&.{.{ .line = "" }});
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Project name?",
        .initial_value = "risu",
    });

    const answer = try prompt.run();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("", answer);
}

test "initial value is rendered and default value is the empty fallback" {
    var input = KeyInputSequence.init(&.{
        .clear_line,
        .enter,
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Project name?",
        .initial_value = "draft",
        .default_value = "risu",
        .render = renderKeyFrame,
    });

    const answer = try prompt.runKeys(input.asInput());
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("risu", answer);
    try std.testing.expectEqualStrings("draft|\n|\nrisu|\n", output.items());
}

test "initial value is editable" {
    var input = KeyInputSequence.init(&.{
        .{ .character = 'X' },
        .enter,
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Project name?",
        .initial_value = "draft",
        .render = renderKeyFrame,
    });

    const answer = try prompt.runKeys(input.asInput());
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("draftX", answer);
    try std.testing.expectEqualStrings("draft|\ndraftX|\ndraftX|\n", output.items());
}

test "line prompt uses default value instead of initial value for empty input" {
    var input = LineInput.init(&.{.{ .line = "" }});
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Project name?",
        .initial_value = "draft",
        .default_value = "risu",
    });

    const answer = try prompt.run();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("risu", answer);
}

test "an already aborted signal cancels before rendering or reading input" {
    var controller = AbortController.init();
    controller.abort();
    var input = LineInput.init(&.{.{ .line = "Ada" }});
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Your name?",
        .signal = controller.signal(),
    });

    try std.testing.expectError(error.Cancelled, prompt.run());
    try std.testing.expectEqual(PromptState.cancelled, prompt.state());
    try std.testing.expectEqualStrings("", output.items());
}

const AbortDuringReadInput = struct {
    controller: *AbortController,

    fn asInput(self: *AbortDuringReadInput) Input {
        return .{
            .context = self,
            .read_line_fn = readLine,
        };
    }

    fn readLine(context: *anyopaque, _: ?AbortSignal) Input.ReadError![]const u8 {
        const self: *AbortDuringReadInput = @ptrCast(@alignCast(context));
        self.controller.abort();
        return "Ada";
    }
};

test "an abort that occurs during input is observed before submission" {
    var controller = AbortController.init();
    var input = AbortDuringReadInput{ .controller = &controller };
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Your name?",
        .signal = controller.signal(),
    });

    try std.testing.expectError(error.Cancelled, prompt.run());
    try std.testing.expectEqual(PromptState.cancelled, prompt.state());
}

const AbortDuringKeyReadInput = struct {
    controller: *AbortController,

    fn asInput(self: *AbortDuringKeyReadInput) KeyInput {
        return .{
            .context = self,
            .read_key_fn = readKey,
        };
    }

    fn readKey(context: *anyopaque, _: ?AbortSignal) Input.ReadError!KeyEvent {
        const self: *AbortDuringKeyReadInput = @ptrCast(@alignCast(context));
        self.controller.abort();
        return .enter;
    }
};

test "an abort that occurs during key input is observed before submission" {
    var controller = AbortController.init();
    var input = AbortDuringKeyReadInput{ .controller = &controller };
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Your name?",
        .signal = controller.signal(),
    });

    try std.testing.expectError(error.Cancelled, prompt.runKeys(input.asInput()));
    try std.testing.expectEqual(PromptState.cancelled, prompt.state());
}

test "placeholder is included in the rendered prompt" {
    var input = LineInput.init(&.{.{ .line = "risu" }});
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Project name?",
        .placeholder = "my-project",
    });

    const answer = try prompt.run();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("Project name? [my-project] Project name? risu ", output.items());
}

test "placeholder is omitted from an empty submitted final frame" {
    var input = LineInput.init(&.{.{ .line = "" }});
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Project name?",
        .placeholder = "my-project",
    });

    const answer = try prompt.run();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("", answer);
    try std.testing.expectEqualStrings("Project name? [my-project] Project name? ", output.items());
}

test "cancellation is terminal and cannot be submitted" {
    var input = LineInput.init(&.{.{ .cancel = {} }});
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Continue?",
    });

    try std.testing.expectError(error.Cancelled, prompt.run());
    try std.testing.expectEqual(PromptState.cancelled, prompt.state());
    try std.testing.expectError(error.AlreadyStarted, prompt.run());
}

test "prompt state transitions reject invalid operations" {
    var prompt = Prompt.init("Message");

    try prompt.begin();
    try std.testing.expectEqual(PromptState.active, prompt.state());
    try std.testing.expectError(error.AlreadyStarted, prompt.begin());
    try prompt.submit();
    try std.testing.expectEqual(PromptState.submitted, prompt.state());
    try std.testing.expectError(error.InvalidState, prompt.cancel());
}

test "end of input cancels an active prompt" {
    var input = LineInput.init(&.{});
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Answer?",
    });

    try std.testing.expectError(error.EndOfInput, prompt.run());
    try std.testing.expectEqual(PromptState.cancelled, prompt.state());
}

test "line prompt reports missing input explicitly" {
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Answer?",
    });

    try std.testing.expectError(error.InputFailed, prompt.run());
    try std.testing.expectEqual(PromptState.cancelled, prompt.state());
    try std.testing.expectEqualStrings("", output.items());
}

fn renderMarker(output: Output, view: TextPrompt.RenderContext) Output.WriteError!void {
    try output.write("[");
    try output.write(@tagName(view.state));
    try output.write("] ");
    try output.write(view.message);
    if (view.placeholder) |placeholder| {
        try output.write(" [");
        try output.write(placeholder);
        try output.write("]");
    }
    if (view.validation_error) |message| {
        try output.write(" ! ");
        try output.write(message);
    }
    try output.write(" ");
}

test "text prompt accepts a custom renderer" {
    var input = LineInput.init(&.{
        .{ .line = "A" },
        .{ .line = "Ada" },
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Your name?",
        .placeholder = "Ada",
        .validate = atLeastTwoCharacters,
        .render = renderMarker,
    });

    const answer = try prompt.run();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("Ada", answer);
    try std.testing.expectEqualStrings(
        "[active] Your name? [Ada] [active] Your name? [Ada] ! Use at least two characters. " ++
            "[submitted] Your name? [Ada] ",
        output.items(),
    );
}

fn renderKeyFrame(output: Output, view: TextPrompt.RenderContext) Output.WriteError!void {
    const displayed_value = view.submitted_value orelse view.value;
    const displayed_cursor = if (view.submitted_value != null) displayed_value.len else view.cursor;
    try output.write(displayed_value[0..displayed_cursor]);
    try output.write("|");
    try output.write(displayed_value[displayed_cursor..]);
    if (view.validation_error) |message| {
        try output.write(" error: ");
        try output.write(message);
    }
    try output.write("\n");
}

test "text prompt edits key events and submits the current value" {
    var input = KeyInputSequence.init(&.{
        .{ .character = 'A' },
        .{ .character = 'd' },
        .{ .character = 'a' },
        .left,
        .backspace,
        .{ .character = 'd' },
        .right,
        .enter,
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Your name?",
        .render = renderKeyFrame,
    });

    const answer = try prompt.runKeys(input.asInput());
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("Ada", answer);
    try std.testing.expectEqualStrings(
        "|\nA|\nAd|\nAda|\nAd|a\nA|a\nAd|a\nAda|\nAda|\n",
        output.items(),
    );
    try std.testing.expectEqual(PromptState.submitted, prompt.state());
}

test "key prompt retries validation and supports escape cancellation" {
    var input = KeyInputSequence.init(&.{
        .{ .character = 'A' },
        .enter,
        .{ .character = 'd' },
        .{ .character = 'a' },
        .enter,
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Your name?",
        .validate = atLeastTwoCharacters,
        .render = renderKeyFrame,
    });

    const answer = try prompt.runKeys(input.asInput());
    defer std.testing.allocator.free(answer);
    try std.testing.expectEqualStrings("Ada", answer);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "A| error: Use at least two characters.") != null);

    var cancel_input = KeyInputSequence.init(&.{.escape});
    var cancel_output = BufferOutput.init(std.testing.allocator);
    defer cancel_output.deinit();
    var cancel_prompt = TextPrompt.init(std.testing.allocator, null, cancel_output.asOutput(), .{
        .message = "Continue?",
    });

    try std.testing.expectError(error.Cancelled, cancel_prompt.runKeys(cancel_input.asInput()));
    try std.testing.expectEqual(PromptState.cancelled, cancel_prompt.state());
}

test "key prompt clears the current line" {
    var input = KeyInputSequence.init(&.{
        .{ .character = 'A' },
        .{ .character = 'd' },
        .clear_line,
        .{ .character = 'Z' },
        .enter,
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Your name?",
        .render = renderKeyFrame,
    });

    const answer = try prompt.runKeys(input.asInput());
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("Z", answer);
    try std.testing.expectEqualStrings("|\nA|\nAd|\n|\nZ|\nZ|\n", output.items());
}

test "key prompt supports common Unix editing controls" {
    var input = KeyInputSequence.init(&.{
        .{ .character = 'A' },
        .{ .character = 'd' },
        .{ .character = 'a' },
        .{ .character = ' ' },
        .{ .character = 'o' },
        .{ .character = 'l' },
        .{ .character = 'd' },
        .home,
        .{ .character = 'X' },
        .end,
        .left,
        .left,
        .kill_to_end,
        .delete_word,
        .home,
        .right,
        .delete_forward,
        .enter,
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Your name?",
        .render = renderKeyFrame,
    });

    const answer = try prompt.runKeys(input.asInput());
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("Xda ", answer);
}

test "key prompt treats delete-forward on an empty value as EOF" {
    var input = KeyInputSequence.init(&.{.delete_forward});
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Your name?",
        .render = renderKeyFrame,
    });

    try std.testing.expectError(error.EndOfInput, prompt.runKeys(input.asInput()));
    try std.testing.expectEqual(PromptState.cancelled, prompt.state());
    try std.testing.expectEqualStrings("|\n|\n", output.items());
}

test "key prompt edits UTF-8 code points without splitting them" {
    var input = KeyInputSequence.init(&.{
        .{ .character = '界' },
        .{ .character = 'A' },
        .left,
        .backspace,
        .{ .character = '你' },
        .enter,
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Name?",
        .render = renderKeyFrame,
    });

    const answer = try prompt.runKeys(input.asInput());
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("你A", answer);
    try std.testing.expectEqualStrings("|\n界|\n界A|\n界|A\n|A\n你|A\n你A|\n", output.items());
}

test "key prompt forward-deletes one UTF-8 code point" {
    var input = KeyInputSequence.init(&.{
        .{ .character = '界' },
        .{ .character = 'A' },
        .home,
        .right,
        .delete_forward,
        .enter,
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Name?",
        .render = renderKeyFrame,
    });

    const answer = try prompt.runKeys(input.asInput());
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("界", answer);
}

test "key prompt moves by UTF-8-safe whitespace-delimited words" {
    var input = KeyInputSequence.init(&.{
        .word_left,
        .{ .character = 'X' },
        .word_left,
        .word_left,
        .{ .character = 'Y' },
        .word_right,
        .{ .character = 'Z' },
        .enter,
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Name?",
        .initial_value = "one 世界 two",
        .render = renderKeyFrame,
    });

    const answer = try prompt.runKeys(input.asInput());
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("one Y世界Z Xtwo", answer);
}

test "resize events re-render without changing the value" {
    var input = KeyInputSequence.init(&.{
        .{ .character = 'A' },
        .resize,
        .enter,
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Name?",
        .render = renderKeyFrame,
    });

    const answer = try prompt.runKeys(input.asInput());
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("A", answer);
    try std.testing.expectEqualStrings("|\nA|\nA|\nA|\n", output.items());
}

fn rejectEmpty(value: []const u8) ?[]const u8 {
    if (value.len == 0) return "Input is required.";
    return null;
}

fn renderLifecycleFrame(output: Output, view: TextPrompt.RenderContext) Output.WriteError!void {
    try output.write(@tagName(view.state));
    try output.write(":");
    try output.write(view.value);
    try output.write("=>");
    if (view.submitted_value) |submitted_value| {
        try output.write(submitted_value);
    } else {
        try output.write("-");
    }
    if (view.validation_error) |message| {
        try output.write("!");
        try output.write(message);
    }
    try output.write("\n");
}

test "text prompt validates raw input before resolving the default" {
    var input = LineInput.init(&.{
        .{ .line = "" },
        .{ .line = "Ada" },
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Your name?",
        .default_value = "Grace",
        .validate = rejectEmpty,
        .render = renderLifecycleFrame,
    });

    const answer = try prompt.run();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("Ada", answer);
    try std.testing.expectEqualStrings(
        "active:=>-\n" ++
            "active:=>-!Input is required.\n" ++
            "submitted:Ada=>Ada\n",
        output.items(),
    );
}

test "accepted empty input exposes a resolved default only in the submitted frame" {
    var input = LineInput.init(&.{.{ .line = "" }});
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Project?",
        .default_value = "risu",
        .render = renderLifecycleFrame,
    });

    const answer = try prompt.run();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("risu", answer);
    try std.testing.expectEqualStrings("active:=>-\nsubmitted:=>risu\n", output.items());
}

test "line validation error preserves the rejected value" {
    var input = LineInput.init(&.{
        .{ .line = "A" },
        .{ .line = "Ada" },
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Your name?",
        .validate = atLeastTwoCharacters,
        .render = renderLifecycleFrame,
    });

    const answer = try prompt.run();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings("Ada", answer);
    try std.testing.expect(std.mem.indexOf(u8, output.items(), "active:A=>-!Use at least two characters.") != null);
}

test "key cancellation renders the typed value in a final frame" {
    var input = KeyInputSequence.init(&.{
        .{ .character = 'x' },
        .escape,
    });
    var output = BufferOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, null, output.asOutput(), .{
        .message = "Value?",
        .render = renderLifecycleFrame,
    });

    try std.testing.expectError(error.Cancelled, prompt.runKeys(input.asInput()));
    try std.testing.expectEqualStrings(
        "active:=>-\nactive:x=>-\ncancelled:x=>-\n",
        output.items(),
    );
}

const RecordingFrameOutput = struct {
    allocator: Allocator,
    frame: std.ArrayList(u8) = .empty,
    committed: std.ArrayList(u8) = .empty,
    in_frame: bool = false,

    fn init(allocator: Allocator) RecordingFrameOutput {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RecordingFrameOutput) void {
        self.frame.deinit(self.allocator);
        self.committed.deinit(self.allocator);
    }

    fn asOutput(self: *RecordingFrameOutput) Output {
        return .{
            .context = self,
            .write_fn = write,
            .begin_frame_fn = beginFrame,
            .finish_frame_fn = finishFrame,
        };
    }

    fn write(context: *anyopaque, bytes: []const u8) Output.WriteError!void {
        const self: *RecordingFrameOutput = @ptrCast(@alignCast(context));
        const destination = if (self.in_frame) &self.frame else &self.committed;
        destination.appendSlice(self.allocator, bytes) catch return error.WriteFailed;
    }

    fn beginFrame(context: *anyopaque) Output.WriteError!void {
        const self: *RecordingFrameOutput = @ptrCast(@alignCast(context));
        self.frame.clearRetainingCapacity();
        self.in_frame = true;
    }

    fn finishFrame(context: *anyopaque, commit: bool) Output.WriteError!void {
        const self: *RecordingFrameOutput = @ptrCast(@alignCast(context));
        defer {
            self.frame.clearRetainingCapacity();
            self.in_frame = false;
        }
        if (!commit) return;
        self.committed.append(self.allocator, '[') catch return error.WriteFailed;
        self.committed.appendSlice(self.allocator, self.frame.items) catch return error.WriteFailed;
        self.committed.append(self.allocator, ']') catch return error.WriteFailed;
    }
};

test "renderer writes are committed as atomic frames" {
    var input = LineInput.init(&.{.{ .line = "Ada" }});
    var output = RecordingFrameOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Name?",
        .render = renderLifecycleFrame,
    });

    const answer = try prompt.run();
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings(
        "[active:=>-\n][submitted:Ada=>Ada\n]",
        output.committed.items,
    );
}

fn renderPartialFailure(output: Output, _: TextPrompt.RenderContext) Output.WriteError!void {
    try output.write("partial");
    return error.WriteFailed;
}

test "failed renderer discards its partial frame" {
    var input = LineInput.init(&.{.{ .line = "Ada" }});
    var output = RecordingFrameOutput.init(std.testing.allocator);
    defer output.deinit();

    var prompt = TextPrompt.init(std.testing.allocator, input.asInput(), output.asOutput(), .{
        .message = "Name?",
        .render = renderPartialFailure,
    });

    try std.testing.expectError(error.OutputFailed, prompt.run());
    try std.testing.expectEqualStrings("", output.committed.items);
}

const CancellationAwareLineInput = struct {
    controller: *AbortController,
    saw_signal: bool = false,

    fn asInput(self: *CancellationAwareLineInput) Input {
        return .{ .context = self, .read_line_fn = readLine };
    }

    fn readLine(context: *anyopaque, signal: ?AbortSignal) Input.ReadError![]const u8 {
        const self: *CancellationAwareLineInput = @ptrCast(@alignCast(context));
        const abort_signal = signal orelse return error.ReadFailed;
        self.saw_signal = true;
        self.controller.abort();
        if (abort_signal.isAborted()) return error.Cancelled;
        return error.ReadFailed;
    }
};

const CancellationAwareKeyInput = struct {
    controller: *AbortController,
    saw_signal: bool = false,

    fn asInput(self: *CancellationAwareKeyInput) KeyInput {
        return .{ .context = self, .read_key_fn = readKey };
    }

    fn readKey(context: *anyopaque, signal: ?AbortSignal) Input.ReadError!KeyEvent {
        const self: *CancellationAwareKeyInput = @ptrCast(@alignCast(context));
        const abort_signal = signal orelse return error.ReadFailed;
        self.saw_signal = true;
        self.controller.abort();
        if (abort_signal.isAborted()) return error.Cancelled;
        return error.ReadFailed;
    }
};

test "line and key input adapters receive the abort signal" {
    var line_controller = AbortController.init();
    var line_input = CancellationAwareLineInput{ .controller = &line_controller };
    var line_output = BufferOutput.init(std.testing.allocator);
    defer line_output.deinit();
    var line_prompt = TextPrompt.init(std.testing.allocator, line_input.asInput(), line_output.asOutput(), .{
        .message = "Line?",
        .signal = line_controller.signal(),
    });

    try std.testing.expectError(error.Cancelled, line_prompt.run());
    try std.testing.expect(line_input.saw_signal);

    var key_controller = AbortController.init();
    var key_input = CancellationAwareKeyInput{ .controller = &key_controller };
    var key_output = BufferOutput.init(std.testing.allocator);
    defer key_output.deinit();
    var key_prompt = TextPrompt.init(std.testing.allocator, null, key_output.asOutput(), .{
        .message = "Key?",
        .signal = key_controller.signal(),
    });

    try std.testing.expectError(error.Cancelled, key_prompt.runKeys(key_input.asInput()));
    try std.testing.expect(key_input.saw_signal);
}

test "risu module loads" {
    try std.testing.expect(true);
}
