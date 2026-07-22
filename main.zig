const std = @import("std");
const linux = std.os.linux;

const wayland_wl_registry_event_global_opcode : u16 = 0;
const wayland_wl_callback_event_done_opcode : u16 = 0;
const wayland_display_object_id : u32 = 1;
const wayland_wl_display_get_registry_opcode : u16 = 1;
const wayland_wl_display_event_delete_id_opcode : u16 = 1;
const wayland_wl_display_sync_opcode : u16 = 0;
const wayland_wl_registry_bind_opcode : u16 = 0;

var wayland_rolling_object_id : u32 = 1;

const WaylandMessageHeader = extern struct {
    object_id : u32 = undefined,
    size_and_opcode : u32 = undefined,
};

const State = struct {
    wl_registry : u32 = undefined,
};

pub fn main(init: std.process.Init) !void {
    const fd = try wayland_display_connect(init.environ_map, init.gpa);
    defer _ = linux.close(fd);

    var state = State{
        .wl_registry = try wayland_wl_display_get_registry(fd),
    };

    const sync_id = try wayland_wl_display_sync(fd);
    try wayland_read_event_message(fd, &state, sync_id);

    // for the next steps, i added:
    // const wayland_wl_display_sync_opcode : u16 = 0;
    // const wayland_wl_registry_bind_opcode : u16 = 0;
    //
    //     from my understanding after get_registry (which we implemented)
    //     we have to call wl_display_sync so we can retrive the done
    //     event thus ensuring us that all the objects available have 
    //     been read (or the ones we needed at least).
    //     (DONE)
    //
    // then we can bind to wl_output using wl_registry_bind.
    // Now that we have wl_output object we can call
    // zwlr_gamma_control_manager_v1::get_gamma_control::get_gamma_control(
    //      id: new_id<zwlr_gamma_control_v1>, output: object<wl_output>
    // )
    //
    // and we are going to use it to call
    // zwlr_gamma_control_v1::set_gamma(fd: fd) 
    //
    // here im not sure what i should do, the docs say
    // "The file descriptor can be memory-mapped to provide the raw gamma 
    // table, which contains successive gamma ramps for the red, green 
    // and blue channels."
    //
    // i notice the "can", so should i? why? can't i just write into the 
    // unix socket we have already been using? 
    // Im guessing that we should use a memory shared mapped fd to avoid
    // syscalls, but in case of a blue light filter utility, is this
    // really needed?
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

/// might want to: make rolling id a function
///
/// This function sends a wayland message to the connected socket to obtain a 
/// global registry object following the wire protocol format.
/// This is done by making a `get_registry` request to the `wl_display` interface. 
/// The function has the responsability of incrementing `wayland_rolling_object_id` 
/// before using it as `object_id` and then returning it to caller.
///
/// ref: https://wayland.freedesktop.org/docs/book/Protocol.html#wire-format
/// ref: https://wayland-book.com/registry.html

pub fn wayland_wl_display_get_registry(fd: linux.fd_t) !u32 {
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

pub fn wayland_wl_display_sync(fd: linux.fd_t) !u32 {
    const size : u16 = @sizeOf(WaylandMessageHeader) + @sizeOf(@TypeOf(wayland_rolling_object_id));
    const header = WaylandMessageHeader{
        .object_id = wayland_display_object_id,
        .size_and_opcode = @as(u32, size) << 16 | wayland_wl_display_sync_opcode,
    };

    wayland_rolling_object_id = wayland_rolling_object_id + 1;
    const payload = wayland_rolling_object_id;

    const buffer = std.mem.asBytes(&header) ++ std.mem.asBytes(&payload);

    const result = linux.sendto(fd, buffer, size, linux.MSG.DONTWAIT, null, 0);
    if(linux.errno(result) != .SUCCESS) return error.WaylandWlDisplaySyncSendToFailed;

    std.log.info("wl_display@{}.sync: sync={}", .{wayland_display_object_id, wayland_rolling_object_id});
    return wayland_rolling_object_id;
} 

/// might want to: make reading non blocking and use a circular buffer
/// to avoid problems if more the information is split between different
/// recvfrom syscalls.
///
/// This function reads a wayland event message from the connected socket following
/// the wire protocol format.
/// This is done by performing a blocking read on the socket using a 4096 bytes 
/// buffer (not optimal solution), then consuming the message header to obtain 
/// the `object_id`, message size and event opcode before decoding the payload 
/// based on the received event.
/// It keeps reading using syscalls (not optimal, should use shared memory)
/// untils the sync event gets returned.
///
/// important todo: currently, events that are not handled will not
/// get consumed from the buffer thus errors when parsing are possible.
/// We should use an internal moving ptr on the payload when parsing (ex.
/// buf_read_u32(&payload_ptr, &payload_len)) content of events and
/// we always increment by payload size the external moving ptr.
/// This way even not handled events will always be consumed.
pub fn wayland_read_event_message(fd: linux.fd_t, state: *State, sync_id: u32) !void {
    var buffer : [4096]u8 align(4) = undefined;
    var synced = false;

    while(synced == false){
        const result = linux.recvfrom(fd, &buffer, buffer.len, 0, null, null);
        if(linux.errno(result) != .SUCCESS) return error.SocketConsumeWaylandHeaderFailed;
        
        var moving_ptr : [*]u8 = &buffer; 
        var msg_len : usize = result;

        while(msg_len > 0) {
            if(msg_len < 8) return error.IncompleteWaylandHeader;

            const object_id       : u32 = try buf_read_u32(&moving_ptr, &msg_len);
            const size_and_opcode : u32 = try buf_read_u32(&moving_ptr, &msg_len);
            const size            : u16 = @truncate(size_and_opcode >> 16);
            const opcode          : u16 = @truncate(size_and_opcode);

            std.log.info("object_id {d:>10}\t size {d:>6}\t opcode {d:>6}\n", .{object_id, size, opcode});
            if(object_id == state.*.wl_registry and opcode == wayland_wl_registry_event_global_opcode){
                const name      : u32        = try buf_read_u32(&moving_ptr, &msg_len);
                const interface : []const u8 = try buf_read_string(&moving_ptr, &msg_len);
                const version   : u32        = try buf_read_u32(&moving_ptr, &msg_len);
                std.log.info("\t↳ (name: {},interface: {s},version: {})\n", .{name, interface, version});
            }
            if(object_id == sync_id and opcode == wayland_wl_callback_event_done_opcode){
                const callback_data : u32 = try buf_read_u32(&moving_ptr, &msg_len);
                synced = true;
                std.log.info("\t↳ (callback_data: {})\n", .{callback_data});
            }
            if(object_id == wayland_display_object_id and opcode == wayland_wl_display_event_delete_id_opcode){
                const deleted_id : u32 = try buf_read_u32(&moving_ptr, &msg_len);
                std.log.info("\t↳ (deleted_id: {})\n", .{deleted_id});
            }
        }
    }
}

pub fn buf_read_string(buf: *[*]u8, buf_size: *usize) ![]const u8{
    // this length, includes null terminator.
    const length = try buf_read_u32(buf, buf_size);

    if(length == 0) return "";
    if(buf_size.* < length) return error.BufferSizeTooSmall;

    const string : []const u8 = buf.*[0..length-1];
    buf.* += length;
    buf_size.* -= length;

    const padding = (4 - (length % 4)) % 4;
    if(buf_size.* < padding) return error.BufferSizeTooSmall;
    buf.* += padding;
    buf_size.* -= padding;

    return string;
}

pub fn buf_read_u32(buf: *[*]u8, buf_size: *usize) !u32{
    if(buf_size.* < @sizeOf(u32)) return error.BufferSizeTooSmall;

    const result : u32 = std.mem.readInt(u32, @ptrCast(buf.*), .little);
    buf.* += @sizeOf(u32);
    buf_size.* -= @sizeOf(u32);

    return result;
}
