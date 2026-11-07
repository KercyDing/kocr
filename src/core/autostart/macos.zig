//! macOS login item through SMAppService (macOS 13 and later).

const std = @import("std");

const objc = struct {
    const Object = *opaque {};
    const SEL = *opaque {};

    extern fn objc_getClass(name: [*:0]const u8) ?Object;
    extern fn sel_registerName(name: [*:0]const u8) SEL;
    extern fn objc_msgSend() void;
};

fn msgSendObject(target: objc.Object, selector: [:0]const u8) objc.Object {
    const function: *const fn (objc.Object, objc.SEL) callconv(.c) objc.Object = @ptrCast(&objc.objc_msgSend);
    return function(target, objc.sel_registerName(selector));
}

fn service() ?objc.Object {
    const class = objc.objc_getClass("SMAppService") orelse return null;
    return msgSendObject(class, "mainAppService");
}

pub fn enabled(
    _: std.Io,
    _: std.mem.Allocator,
    _: *const std.process.Environ.Map,
) !bool {
    const app = service() orelse return false;
    const function: *const fn (objc.Object, objc.SEL) callconv(.c) isize = @ptrCast(&objc.objc_msgSend);
    return function(app, objc.sel_registerName("status")) == 1; // enabled
}

pub fn set(
    _: std.Io,
    _: std.mem.Allocator,
    _: *const std.process.Environ.Map,
    install: bool,
    _: []const u8,
) !void {
    const app = service() orelse return error.UnsupportedPlatform;
    const selector: [:0]const u8 = if (install) "registerAndReturnError:" else "unregisterAndReturnError:";
    const function: *const fn (objc.Object, objc.SEL, ?*?*anyopaque) callconv(.c) i8 = @ptrCast(&objc.objc_msgSend);
    var failure: ?*anyopaque = null;
    if (function(app, objc.sel_registerName(selector), &failure) == 0) return error.LoginItemFailed;
}
