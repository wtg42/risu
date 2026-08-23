const std = @import("std");

/// Terminal dimensions measured in character cells.
pub const TerminalSize = struct {
    columns: usize,
    rows: usize,
};

/// Type-erased terminal metrics and Unicode display-width policy.
pub const TerminalCapabilities = struct {
    context: *anyopaque,
    size_fn: *const fn (context: *anyopaque) TerminalSize,
    display_width_fn: *const fn (context: *anyopaque, codepoint: u21) usize,

    pub fn size(self: TerminalCapabilities) TerminalSize {
        const current = self.size_fn(self.context);
        return .{
            .columns = @max(current.columns, 1),
            .rows = @max(current.rows, 1),
        };
    }

    pub fn displayWidth(self: TerminalCapabilities, codepoint: u21) usize {
        return self.display_width_fn(self.context, codepoint);
    }
};

/// Build an output adapter that buffers renderer writes as one frame, wraps
/// visible content, and replaces changed terminal rows without stale output.
pub fn FrameOutput(comptime OutputType: type) type {
    return struct {
        const Self = @This();
        const cursor_hide = "\x1b[?25l";
        const cursor_show = "\x1b[?25h";
        const erase_down = "\x1b[J";

        allocator: std.mem.Allocator,
        destination: OutputType,
        capabilities: TerminalCapabilities,
        frame: std.ArrayList(u8) = .empty,
        previous_frame: std.ArrayList(u8) = .empty,
        in_frame: bool = false,
        has_frame: bool = false,
        cursor_hidden: bool = false,
        deinitialized: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            destination: OutputType,
            capabilities: TerminalCapabilities,
        ) Self {
            return .{
                .allocator = allocator,
                .destination = destination,
                .capabilities = capabilities,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.deinitialized) return;
            self.deinitialized = true;
            if (self.cursor_hidden) {
                self.destination.write(cursor_show) catch {};
                self.cursor_hidden = false;
            }
            self.frame.deinit(self.allocator);
            self.previous_frame.deinit(self.allocator);
        }

        pub fn asOutput(self: *Self) OutputType {
            return .{
                .context = self,
                .write_fn = write,
                .begin_frame_fn = beginFrame,
                .finish_frame_fn = finishFrame,
            };
        }

        fn write(context: *anyopaque, bytes: []const u8) OutputType.WriteError!void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (!self.in_frame) return self.destination.write(bytes);
            self.frame.appendSlice(self.allocator, bytes) catch return error.WriteFailed;
        }

        fn beginFrame(context: *anyopaque) OutputType.WriteError!void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.in_frame or self.deinitialized) return error.WriteFailed;
            self.frame.clearRetainingCapacity();
            self.in_frame = true;
        }

        fn finishFrame(context: *anyopaque, should_commit: bool) OutputType.WriteError!void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (!self.in_frame or self.deinitialized) return error.WriteFailed;
            self.in_frame = false;
            defer self.frame.clearRetainingCapacity();
            if (!should_commit) return;
            try self.commitFrame();
        }

        fn commitFrame(self: *Self) OutputType.WriteError!void {
            var wrapped: std.ArrayList(u8) = .empty;
            defer wrapped.deinit(self.allocator);
            wrapFrame(
                self.allocator,
                self.capabilities,
                self.frame.items,
                &wrapped,
            ) catch return error.WriteFailed;

            if (self.has_frame and std.mem.eql(u8, self.previous_frame.items, wrapped.items)) return;

            if (!self.cursor_hidden) {
                try self.destination.write(cursor_hide);
                self.cursor_hidden = true;
            }

            if (!self.has_frame) {
                try self.destination.write(wrapped.items);
            } else {
                try self.replaceFrame(wrapped.items);
            }

            self.previous_frame.clearRetainingCapacity();
            self.previous_frame.appendSlice(self.allocator, wrapped.items) catch return error.WriteFailed;
            self.has_frame = true;
        }

        fn replaceFrame(self: *Self, next_frame: []const u8) OutputType.WriteError!void {
            const previous_lines = lineCount(self.previous_frame.items);
            const next_lines = lineCount(next_frame);
            const rows = self.capabilities.size().rows;
            var first_changed = firstChangedLine(self.previous_frame.items, next_frame);

            if (previous_lines > rows or next_lines > rows) {
                first_changed = 0;
            } else if (first_changed >= next_lines) {
                first_changed = next_lines - 1;
            }

            const previous_last_line = previous_lines - 1;
            const requested_up = previous_last_line -| first_changed;
            const move_up = @min(requested_up, rows - 1);

            try self.destination.write("\r");
            if (move_up > 0) {
                var sequence_buffer: [32]u8 = undefined;
                const sequence = std.fmt.bufPrint(&sequence_buffer, "\x1b[{d}A", .{move_up}) catch {
                    return error.WriteFailed;
                };
                try self.destination.write(sequence);
            }
            try self.destination.write(erase_down);

            const suffix_line = if (previous_lines > rows or next_lines > rows) 0 else first_changed;
            try self.destination.write(next_frame[lineOffset(next_frame, suffix_line)..]);
        }
    };
}

fn wrapFrame(
    allocator: std.mem.Allocator,
    capabilities: TerminalCapabilities,
    input: []const u8,
    output: *std.ArrayList(u8),
) !void {
    const columns = capabilities.size().columns;
    var column: usize = 0;
    var index: usize = 0;

    while (index < input.len) {
        const byte = input[index];
        if (byte == '\n') {
            try output.append(allocator, byte);
            column = 0;
            index += 1;
            continue;
        }
        if (byte == '\r') {
            try output.append(allocator, byte);
            index += 1;
            continue;
        }
        if (byte == 0x1b) {
            const end = ansiSequenceEnd(input, index);
            try output.appendSlice(allocator, input[index..end]);
            index = end;
            continue;
        }

        const sequence_length: usize = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const available_length = @min(sequence_length, input.len - index);
        const sequence = input[index .. index + available_length];
        const codepoint = std.unicode.utf8Decode(sequence) catch @as(u21, byte);
        const width = capabilities.displayWidth(codepoint);

        if (width > 0 and column > 0 and column + width > columns) {
            try output.append(allocator, '\n');
            column = 0;
        }
        try output.appendSlice(allocator, sequence);
        column += width;
        index += available_length;
    }
}

fn ansiSequenceEnd(input: []const u8, start: usize) usize {
    if (start + 1 >= input.len) return start + 1;
    if (input[start + 1] != '[') return @min(start + 2, input.len);

    var index = start + 2;
    while (index < input.len) : (index += 1) {
        if (input[index] >= 0x40 and input[index] <= 0x7e) return index + 1;
    }
    return input.len;
}

fn lineCount(frame: []const u8) usize {
    var count: usize = 1;
    for (frame) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn firstChangedLine(previous: []const u8, next: []const u8) usize {
    var previous_lines = std.mem.splitScalar(u8, previous, '\n');
    var next_lines = std.mem.splitScalar(u8, next, '\n');
    var index: usize = 0;
    while (true) : (index += 1) {
        const previous_line = previous_lines.next();
        const next_line = next_lines.next();
        if (previous_line == null or next_line == null) return index;
        if (!std.mem.eql(u8, previous_line.?, next_line.?)) return index;
    }
}

fn lineOffset(frame: []const u8, line: usize) usize {
    if (line == 0) return 0;
    var current_line: usize = 0;
    for (frame, 0..) |byte, index| {
        if (byte != '\n') continue;
        current_line += 1;
        if (current_line == line) return index + 1;
    }
    return frame.len;
}

const TestOutput = struct {
    pub const WriteError = error{WriteFailed};

    context: *anyopaque,
    write_fn: *const fn (context: *anyopaque, bytes: []const u8) WriteError!void,
    begin_frame_fn: ?*const fn (context: *anyopaque) WriteError!void = null,
    finish_frame_fn: ?*const fn (context: *anyopaque, commit: bool) WriteError!void = null,

    fn write(self: TestOutput, bytes: []const u8) WriteError!void {
        return self.write_fn(self.context, bytes);
    }

    fn beginFrame(self: TestOutput) WriteError!void {
        if (self.begin_frame_fn) |begin_frame| try begin_frame(self.context);
    }

    fn finishFrame(self: TestOutput, should_commit: bool) WriteError!void {
        if (self.finish_frame_fn) |finish_frame| try finish_frame(self.context, should_commit);
    }
};

const TestDestination = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) TestDestination {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestDestination) void {
        self.bytes.deinit(self.allocator);
    }

    fn asOutput(self: *TestDestination) TestOutput {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) TestOutput.WriteError!void {
        const self: *TestDestination = @ptrCast(@alignCast(context));
        self.bytes.appendSlice(self.allocator, bytes) catch return error.WriteFailed;
    }
};

const TestCapabilities = struct {
    size_value: TerminalSize,

    fn asCapabilities(self: *TestCapabilities) TerminalCapabilities {
        return .{
            .context = self,
            .size_fn = size,
            .display_width_fn = displayWidth,
        };
    }

    fn size(context: *anyopaque) TerminalSize {
        const self: *TestCapabilities = @ptrCast(@alignCast(context));
        return self.size_value;
    }

    fn displayWidth(_: *anyopaque, codepoint: u21) usize {
        return if (codepoint == '界') 2 else 1;
    }
};

fn commit(output: TestOutput, fragments: []const []const u8) !void {
    try output.beginFrame();
    for (fragments) |fragment| try output.write(fragment);
    try output.finishFrame(true);
}

test "terminal frame wraps ASCII at current columns" {
    var destination = TestDestination.init(std.testing.allocator);
    defer destination.deinit();
    var capabilities = TestCapabilities{ .size_value = .{ .columns = 4, .rows = 10 } };
    var framed = FrameOutput(TestOutput).init(
        std.testing.allocator,
        destination.asOutput(),
        capabilities.asCapabilities(),
    );
    defer framed.deinit();

    try commit(framed.asOutput(), &.{"abcde"});

    try std.testing.expectEqualStrings("\x1b[?25labcd\ne", destination.bytes.items);
}

test "terminal frame ignores ANSI width and uses injected character width" {
    var ansi_destination = TestDestination.init(std.testing.allocator);
    defer ansi_destination.deinit();
    var ansi_capabilities = TestCapabilities{ .size_value = .{ .columns = 4, .rows = 10 } };
    var ansi_framed = FrameOutput(TestOutput).init(
        std.testing.allocator,
        ansi_destination.asOutput(),
        ansi_capabilities.asCapabilities(),
    );
    defer ansi_framed.deinit();

    try commit(ansi_framed.asOutput(), &.{ "\x1b[31mab", "cde\x1b[0m" });
    try std.testing.expectEqualStrings(
        "\x1b[?25l\x1b[31mabcd\ne\x1b[0m",
        ansi_destination.bytes.items,
    );

    var wide_destination = TestDestination.init(std.testing.allocator);
    defer wide_destination.deinit();
    var wide_capabilities = TestCapabilities{ .size_value = .{ .columns = 3, .rows = 10 } };
    var wide_framed = FrameOutput(TestOutput).init(
        std.testing.allocator,
        wide_destination.asOutput(),
        wide_capabilities.asCapabilities(),
    );
    defer wide_framed.deinit();

    try commit(wide_framed.asOutput(), &.{"A界B"});
    try std.testing.expectEqualStrings("\x1b[?25lA界\nB", wide_destination.bytes.items);
}

test "terminal frame skips identical content and redraws after resize" {
    var destination = TestDestination.init(std.testing.allocator);
    defer destination.deinit();
    var capabilities = TestCapabilities{ .size_value = .{ .columns = 5, .rows = 10 } };
    var framed = FrameOutput(TestOutput).init(
        std.testing.allocator,
        destination.asOutput(),
        capabilities.asCapabilities(),
    );
    defer framed.deinit();
    const output = framed.asOutput();

    try commit(output, &.{"abcdef"});
    const first_length = destination.bytes.items.len;
    try commit(output, &.{"abcdef"});
    try std.testing.expectEqual(first_length, destination.bytes.items.len);

    capabilities.size_value.columns = 3;
    try commit(output, &.{"abcdef"});
    try std.testing.expectEqualStrings(
        "\x1b[?25labcde\nf\r\x1b[1A\x1b[Jabc\ndef",
        destination.bytes.items,
    );
}

test "terminal frame clears rows left by a longer frame" {
    var destination = TestDestination.init(std.testing.allocator);
    defer destination.deinit();
    var capabilities = TestCapabilities{ .size_value = .{ .columns = 20, .rows = 10 } };
    var framed = FrameOutput(TestOutput).init(
        std.testing.allocator,
        destination.asOutput(),
        capabilities.asCapabilities(),
    );
    defer framed.deinit();
    const output = framed.asOutput();

    try commit(output, &.{"one\ntwo\nthree"});
    try commit(output, &.{"one"});

    try std.testing.expectEqualStrings(
        "\x1b[?25lone\ntwo\nthree\r\x1b[2A\x1b[Jone",
        destination.bytes.items,
    );
}

test "terminal frame restores the cursor during cleanup" {
    var destination = TestDestination.init(std.testing.allocator);
    defer destination.deinit();
    var capabilities = TestCapabilities{ .size_value = .{ .columns = 20, .rows = 10 } };
    var framed = FrameOutput(TestOutput).init(
        std.testing.allocator,
        destination.asOutput(),
        capabilities.asCapabilities(),
    );

    try commit(framed.asOutput(), &.{"frame"});
    framed.deinit();

    try std.testing.expectEqualStrings(
        "\x1b[?25lframe\x1b[?25h",
        destination.bytes.items,
    );
}
