const std = @import("std");
const platform = @import("../platform/platform.zig");

pub const App = struct {
    runFn: fn () void,

    windows: std.ArrayList(*platform.Window) = undefined,

    const Self = @This();

    pub fn init(self: *Self) !void {
        // start platform stuff
        try platform.init();
        // window things
        self.windows = std.ArrayList(*platform.Window).init(platform.allocator);
        try self.windows.append(try platform.createWindow("title1", .{.x=100, .y=100, .w=200, .h=200}));
        try self.windows.append(try platform.createWindow("title2", .{.x=100, .y=100, .w=200, .h=200}));
    }

    // TODO: suspend and stopped states

    pub fn run(self: *Self) void {
        while (!platform.shouldQuit()) {
            // flush platform
            // TODO: add to message queue
            while (platform.flushMsg()) |event| {
                //switch (event) {
                //    //.WindowClose => |id| std.log.info("close window: {}", .{id}),
                //    else => continue,
                //}
            }
            self.runFn();
        }
    }

    pub fn deinit(self: *Self) void {
        // shutdown platform stuff
        for (self.windows.items) |win| {
            platform.destroyWindow(win);
        }
        self.windows.deinit();
        platform.deinit();
    }
};
