const std = @import("std");
const os = std.os;

const Window = @import("../window.zig");
const LinuxWindow = @import("window.zig").LinuxWindow;
const Geom = @import("../window.zig").Geom;
const Event = @import("../../core/event.zig").Event;

const input = @import("../../core/input.zig");

usingnamespace @import("xcb_decls.zig");

pub const allocator = std.heap.page_allocator;

var display: *Display = undefined;
var connection: *xcb_connection_t = undefined;
var screen: *xcb_screen_t = undefined;

// TODO: turn this into ringbuffer
var windows: []?LinuxWindow = undefined;
/// idx of last window
var widx: usize = 0;
//var window_mask: u8 = 0;
var living_windows: usize = 0;

var quit = false;

pub fn shouldQuit() bool {
    return quit;
}

pub fn init() anyerror!void {
    std.log.info("linux startup", .{});

    display = XOpenDisplay(null).?;
    _ = XAutoRepeatOff(display);
    connection = XGetXCBConnection(display);
    if (xcb_connection_has_error(connection) != 0) {
        return error.XcbConnectionFail;
    }
    var itr: xcb_screen_iterator_t = xcb_setup_roots_iterator(xcb_get_setup(connection));
    // Use the last screen
    screen = @ptrCast(*xcb_screen_t, itr.data);


    var act = os.Sigaction{
        .handler = .{ .sigaction = handler },
        .mask = os.empty_sigset,
        .flags = (os.SA_SIGINFO | os.SA_RESETHAND),
    };
    os.sigaction(os.SIGINT, &act, null);

    windows = try allocator.alloc(?LinuxWindow, 5);
}

fn handler(sig: i32, info: *const os.siginfo_t, ctx_ptr: ?*const c_void) callconv(.C) void {
    // TODO: send the quit message and get rid of the platform should quit check
    if (sig == os.SIGINT) {
        quit = true;
    }
}

pub fn deinit() void {
    _ = XAutoRepeatOn(display);
    allocator.free(windows);
    std.log.info("linux shutdown", .{});
}

pub fn flushMsg() void {
    var i: usize = 0;
    var ret: ?Event = null;
    if (xcb_poll_for_event(connection)) |event| {
        // Input events
        switch (event.*.response_type & ~@as(u32, 0x80)) {
            XCB_KEY_PRESS,
            XCB_KEY_RELEASE => {
                const kev = @ptrCast(*xcb_key_press_event_t, event);
                const pressed = event.response_type == XCB_KEY_PRESS;

                const code = kev.detail;
                const key_sym = XkbKeycodeToKeysym(
                    display,
                    code,  //event.xkey.keycode,
                    0,
                    if (code & ShiftMask == 1) 1 else 0);

                const key = translateKey(key_sym);
                std.log.info("key pressed: {}", .{key});
                input.processKey(key, pressed);

            },
            XCB_CLIENT_MESSAGE => {
                const cm = @ptrCast(*xcb_client_message_event_t, event);
                // Window close
                // search through windows to find which one it is equal to
                for (windows) |win| {
                    if (win != null and
                        cm.*.data.data32[0] == win.?.wm_del and 
                        cm.window == win.?.window
                        ) {
                        ret = Event{.WindowClose = cm.window };
                        destroyWindow(&win.?.parent);
                    }
                }
            },
            XCB_BUTTON_PRESS,
            XCB_BUTTON_RELEASE => {
                const kev = @ptrCast(*xcb_key_press_event_t, event);
                const pressed = kev.response_type == XCB_BUTTON_PRESS;
                var btn: input.mouse_btns = undefined;
                switch (kev.detail) {
                    1 => btn = input.mouse_btns.left,
                    2 => btn = input.mouse_btns.middle,
                    3 => btn = input.mouse_btns.right,
                    else => {
                        // TODO: use buttons 4 and 5 to add scrolling
                        std.log.info("button press: {}", .{kev.detail});
                        btn = input.mouse_btns.other;
                    },
                }
                input.processMouseBtn(btn, pressed);
            },
            XCB_MOTION_NOTIFY => {
                const motion = @ptrCast(*xcb_motion_notify_event_t, event);
                input.processMouseMove(motion.event_x, motion.event_y);
            },
            // for resizes
            XCB_CONFIGURE_NOTIFY => {},
            //else => |ev| std.log.info("event: {}", .{ev}),
            else => {},
        }
        _ = xcb_flush(connection);
    }
}

pub fn destroyWindow(window: *const Window) void {
    // get the id of the linux window
    std.log.info("there are {} windows. destroying {}", .{living_windows, window.id});

    // if this window is null then we've already taken care of it
    if (windows[window.id] == null) {
        return;
    }

    var i: usize = 0;
    while (i < windows.len) : (i+=1) {
        // compare to all our windows
        if (window.id == i) {
            // if we are about to destroy the last window then  turn autorepeat back on
            if (living_windows == 1) {
                _ = XAutoRepeatOn(display);
            }
            _ = xcb_destroy_window(connection, windows[window.id].?.window);
            living_windows -= 1;
            // remove from windows list
            windows[window.id] = null;
            return;
        }
    }
}

pub fn createWindow(
    title: []const u8,
    geom: Geom,
) anyerror!*Window {
    if ((widx + 1) > windows.len) {
        return error.TooManyWindows;
    }

    // fill that sucker in
    windows[widx] = try LinuxWindow.init(widx, connection, screen, title, geom);
    widx += 1;
    living_windows += 1;

    return &windows[widx-1].?.parent;
}

fn translateKey(code: u32) input.keys {
    return switch (code) {
        XK_BackSpace=> input.keys.backspace,
        XK_Return=> input.keys.enter,
        XK_Tab=> input.keys.tab,
        //XK_Shift=> input.keys.shift,
        //XK_Control=> input.keys.control,
        XK_Pause=> input.keys.pause,
        XK_Caps_Lock=> input.keys.capital,
        XK_Escape=> input.keys.escape,

        XK_Mode_switch=> input.keys.modechange,

        XK_space=> input.keys.space,
        XK_Prior=> input.keys.prior,
        XK_Next=> input.keys.next,
        XK_End=> input.keys.end,
        XK_Home=> input.keys.home,
        XK_Left=> input.keys.left,
        XK_Up=> input.keys.up,
        XK_Right=> input.keys.right,
        XK_Down=> input.keys.down,
        XK_Select=> input.keys.select,
        XK_Print=> input.keys.print,
        XK_Execute=> input.keys.execute,
        XK_Insert=> input.keys.insert,
        XK_Delete=> input.keys.delete,
        XK_Help=> input.keys.help,

        XK_Meta_L=> input.keys.lwin,  // TODO=> not sure this is right
        XK_Meta_R=> input.keys.rwin,
            // XK_apps=> input.keys.apps, // not supported

            // XK_sleep=> input.keys.sleep, //not supported

        XK_KP_0=> input.keys.numpad0,
        XK_KP_1=> input.keys.numpad1,
        XK_KP_2=> input.keys.numpad2,
        XK_KP_3=> input.keys.numpad3,
        XK_KP_4=> input.keys.numpad4,
        XK_KP_5=> input.keys.numpad5,
        XK_KP_6=> input.keys.numpad6,
        XK_KP_7=> input.keys.numpad7,
        XK_KP_8=> input.keys.numpad8,
        XK_KP_9=> input.keys.numpad9,
        XK_multiply=> input.keys.multiply,
        XK_KP_Add=> input.keys.add,
        XK_KP_Separator=> input.keys.separator,
        XK_KP_Subtract=> input.keys.subtract,
        XK_KP_Decimal=> input.keys.decimal,
        XK_KP_Divide=> input.keys.divide,
        XK_F1=> input.keys.f1,
        XK_F2=> input.keys.f2,
        XK_F3=> input.keys.f3,
        XK_F4=> input.keys.f4,
        XK_F5=> input.keys.f5,
        XK_F6=> input.keys.f6,
        XK_F7=> input.keys.f7,
        XK_F8=> input.keys.f8,
        XK_F9=> input.keys.f9,
        XK_F10=> input.keys.f10,
        XK_F11=> input.keys.f11,
        XK_F12=> input.keys.f12,
        XK_F13=> input.keys.f13,
        XK_F14=> input.keys.f14,
        XK_F15=> input.keys.f15,
        XK_F16=> input.keys.f16,
        XK_F17=> input.keys.f17,
        XK_F18=> input.keys.f18,
        XK_F19=> input.keys.f19,
        XK_F20=> input.keys.f20,
        XK_F21=> input.keys.f21,
        XK_F22=> input.keys.f22,
        XK_F23=> input.keys.f23,
        XK_F24=> input.keys.f24,
        XK_Num_Lock=> input.keys.numlock,
        XK_Scroll_Lock=> input.keys.scroll,
        XK_KP_Equal=> input.keys.numpad_equal,

        XK_Shift_L=>
        input.keys.lshift, XK_Shift_R=>
        input.keys.rshift, XK_Control_L=>
        input.keys.lcontrol, XK_Control_R=>

        input.keys.rcontrol, // XK_Menu=> KEY_LMENU,
        XK_Menu=> input.keys.rmenu,
        XK_semicolon=> input.keys.semicolon,

        XK_plus=> input.keys.plus,
        XK_comma=> input.keys.comma,
        XK_minus=> input.keys.minus,
        XK_period=> input.keys.period,
        XK_slash=> input.keys.slash,
        XK_grave=> input.keys.grave,

        XK_a, XK_A => input.keys.a,
        XK_b, XK_B => input.keys.b,
        XK_c, XK_C => input.keys.c,
        XK_d, XK_D => input.keys.d,
        XK_e, XK_E => input.keys.e,
        XK_f, XK_F => input.keys.f,
        XK_g, XK_G => input.keys.g,
        XK_h, XK_H => input.keys.h,
        XK_i, XK_I => input.keys.i,
        XK_j, XK_J => input.keys.j,
        XK_k, XK_K => input.keys.k,
        XK_l, XK_L => input.keys.l,
        XK_m, XK_M => input.keys.m,
        XK_n, XK_N => input.keys.n,
        XK_o, XK_O => input.keys.o,
        XK_p, XK_P => input.keys.p,
        XK_q, XK_Q => input.keys.q,
        XK_r, XK_R => input.keys.r,
        XK_s, XK_S => input.keys.s,
        XK_t, XK_T => input.keys.t,
        XK_u, XK_U => input.keys.u,
        XK_v, XK_V => input.keys.v,
        XK_w, XK_W => input.keys.w,
        XK_x, XK_X => input.keys.x,
        XK_y, XK_Y => input.keys.y,
        XK_z, XK_Z => input.keys.z,
            // Not supported
            // => KEY_CONVERT,
            // => KEY_NONCONVERT,
        // XK_snapshot=> KEY_SNAPSHOT, // not supported
            // => KEY_ACCEPT,
        else => input.keys.unknown,
    };
}
