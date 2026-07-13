const std = @import("std");
const linux = std.os.linux;

const wayland_display_object_id : u32 = 1;
const wayland_wl_display_get_registry_opcode : u32 = 1;
var wayland_rolling_object_id : u32 = 0;

const WaylandMessageHeader = extern struct {
    object_id : u32,
    size_and_opcode : u32,
};

pub fn main(init: std.process.Init) !void {
    const fd = try wayland_display_connect(init.environ_map, init.gpa);
    defer _ = linux.close(fd);

    const wayland_wl_display_id = try wayland_wl_display_get_registry(fd);

    _ = wayland_wl_display_id;
}

/// This function creates and connects a Unix domain socket to enable
/// future communication with the wayland interface.
/// If successful, returns the file descriptor to the socket.
pub fn wayland_display_connect(env: *std.process.Environ.Map, gpa: std.mem.Allocator) !linux.fd_t {
    const xdg_runtime = env.get("XDG_RUNTIME_DIR") orelse return error.MissingXdgRuntimeDir;
    const wayland_display = env.get("WAYLAND_DISPLAY") orelse return error.MissingWaylandDisplay;

    const wayland_socket_path = try std.mem.concat(gpa, u8, &.{xdg_runtime, "/", wayland_display});
    defer gpa.free(wayland_socket_path);

    var result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    const fd: linux.fd_t = switch(linux.errno(result)){
        .SUCCESS => @intCast(result),
        else => return error.SocketCreationFailed,
    };
    errdefer _ = linux.close(fd);

    var addr = linux.sockaddr.un{
        .family = linux.AF.UNIX,
        .path = undefined,
    };

    if(wayland_socket_path.len >= addr.path.len){
        return error.WaylandSocketPathTooLong;
    }

    @memset(addr.path[0..], 0);
    @memcpy(addr.path[0..wayland_socket_path.len], wayland_socket_path);
    const addr_len = @offsetOf(linux.sockaddr.un, "path") + wayland_socket_path.len;

    result = linux.connect(fd, @ptrCast(&addr), @as(linux.socklen_t, @intCast(addr_len)));
    if(linux.errno(result) != .SUCCESS) return error.SocketConnectionFailed;

    std.log.info("fd to socket: {}", .{fd});
    return fd;
}

// might want to: make rolling id a function
//
// This function sends a wayland message to the connected socket to obtain a 
// global registry object following the wire protocol format.
// This is done by making a `get_registry` request to the `wl_display` interface. 
// The function has the responsability of incrementing `wayland_rolling_object_id` 
// before using it as `object_id` and then returning it to caller.
//
// ref: https://wayland.freedesktop.org/docs/book/Protocol.html#wire-format
// ref: https://wayland-book.com/registry.html

pub fn wayland_wl_display_get_registry(fd: linux.fd_t) !usize{
    const size : u16 = @sizeOf(WaylandMessageHeader) + @sizeOf(@TypeOf(wayland_rolling_object_id));
    const header = WaylandMessageHeader{
        .object_id = wayland_display_object_id,
        .size_and_opcode = @as(u32, size) << 16 | wayland_wl_display_get_registry_opcode,
    };

    wayland_rolling_object_id = wayland_rolling_object_id + 1;
    const payload = wayland_rolling_object_id;

    const buffer = std.mem.asBytes(&header) ++ std.mem.asBytes(&payload);

    const result = linux.sendto(fd, buffer, size, linux.MSG.DONTWAIT, null, 0);
    if(linux.errno(result) != .SUCCESS) return error.WaylandWlDisplayGetRegistrySendToFailed;

    std.log.info("wl_display@{}.get_registry: wl_registry={}", .{wayland_display_object_id, wayland_rolling_object_id});
    return wayland_rolling_object_id;
} 
