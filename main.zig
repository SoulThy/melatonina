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
    object_id       : u32 = undefined,
    size_and_opcode : u32 = undefined,
};

const State = struct {
    wl_registry : u32 = undefined,
    wl_output  : u32 = undefined,
    sync_id     : u32 = undefined,
};

pub fn main(init: std.process.Init) !void {
    const fd = try wayland_display_connect(init.environ_map, init.gpa);
    defer _ = linux.close(fd);

    var state = State{
        .wl_registry = try wayland_wl_display_get_registry(fd),
        .sync_id = try wayland_wl_display_sync(fd),
    };

    try wayland_read_event_message(fd, &state);

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

/// This functions sends a request to the socket pointed by
/// the file descriptor following the wire protocol format.
pub fn wayland_send_request(fd: linux.fd_t, object_id: u32, opcode: u16, args: anytype) !void{
    const field_types = @typeInfo(@TypeOf(args)).@"struct".field_types;
    comptime var payload_size: usize = 0;
    inline for(field_types) |field_type| payload_size += @sizeOf(field_type);

    const total_size : u16 = @sizeOf(WaylandMessageHeader) + payload_size;
    const header = WaylandMessageHeader{
        .object_id = object_id,
        .size_and_opcode = @as(u32, total_size) << 16 | opcode,
    };

    const field_names = @typeInfo(@TypeOf(args)).@"struct".field_names;
    var payload : [payload_size]u8 = undefined;
    comptime var offset : usize = 0;
    inline for(field_names) |field_name| {
        const value = @field(args, field_name);
        const bytes = std.mem.asBytes(&value);
        @memcpy(payload[offset..(offset+bytes.len)], bytes);
        offset += bytes.len;
    }

    const buffer = std.mem.asBytes(&header) ++ payload;

    const result = linux.sendto(fd, buffer, total_size, linux.MSG.DONTWAIT, null, 0);
    if(linux.errno(result) != .SUCCESS) return error.WaylandSendToFailed;
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
    wayland_rolling_object_id += 1;
    const new_id = wayland_rolling_object_id;

    try wayland_send_request(fd, wayland_display_object_id, wayland_wl_display_get_registry_opcode, .{new_id});

    std.log.info("wl_display@{}.get_registry: wl_registry={}", .{wayland_display_object_id, wayland_rolling_object_id});
    return new_id;
} 

/// This function sends a wayland message to the connected socket to send a 
/// sync request following the wire protocol format.
/// This sync object is then used when reading events to ensure
/// that all the information we expect to receive from the server
/// has been sent.
/// The function has the responsability of incrementing `wayland_rolling_object_id` 
/// before using it as `object_id` and then returning it to caller.
pub fn wayland_wl_display_sync(fd: linux.fd_t) !u32 {
    wayland_rolling_object_id += 1;
    const new_id = wayland_rolling_object_id;

    try wayland_send_request(fd, wayland_display_object_id, wayland_wl_display_sync_opcode, .{new_id});

    std.log.info("wl_display@{}.sync: sync={}", .{wayland_display_object_id, wayland_rolling_object_id});
    return new_id;
} 

/// This function sends a wayland message to the connected socket to send a 
/// bind request following the wire protocol format.
/// This bind enables us to make requests to the just binded interface.
/// The function has the responsability of incrementing `wayland_rolling_object_id` 
/// before using it as `object_id` and then returning it to caller.
pub fn wayland_wl_registry_bind(fd: linux.fd_t, wl_registry_obj_id: u32, name: u32) !u32 {
    wayland_rolling_object_id += 1;
    const new_id = wayland_rolling_object_id;

    try wayland_send_request(fd, wl_registry_obj_id, wayland_wl_registry_bind_opcode, .{name, new_id});

    std.log.info("wl_registry@{}.bind: bind={}", .{wayland_display_object_id, wayland_rolling_object_id});
    return new_id;
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
pub fn wayland_read_event_message(fd: linux.fd_t, state: *State) !void {
    var buffer : [4096]u8 = undefined;
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
            const payload_size    : usize = size - @sizeOf(WaylandMessageHeader);

            if(msg_len < payload_size) return error.IncompleteWaylandPayload;

            std.log.info("", .{});
            std.log.info("object_id {d:>10}\t size {d:>6}\t opcode {d:>6}", .{object_id, size, opcode});

            var payload_ptr : [*]u8 = moving_ptr; 
            var payload_left = payload_size;

            if(object_id == state.*.wl_registry and opcode == wayland_wl_registry_event_global_opcode){
                const name      : u32        = try buf_read_u32(&payload_ptr, &payload_left);
                const interface : []const u8 = try buf_read_string(&payload_ptr, &payload_left);
                const version   : u32        = try buf_read_u32(&payload_ptr, &payload_left);
                std.log.info("\t↳ (name: {},interface: {s},version: {})", .{name, interface, version});

                // todo: this is starting to look like 'if' nesting hell, could
                // probably use a string hashmap instead. But for now will do.
                if(std.mem.eql(u8, interface, "wl_output")){
                    state.*.wl_output = try wayland_wl_registry_bind(fd, state.*.wl_registry, name);
                }
            }
            else if(object_id == state.*.sync_id and opcode == wayland_wl_callback_event_done_opcode){
                const callback_data : u32 = try buf_read_u32(&payload_ptr, &payload_left);
                synced = true;
                std.log.info("\t↳ (callback_data: {})", .{callback_data});
            }
            else if(object_id == wayland_display_object_id and opcode == wayland_wl_display_event_delete_id_opcode){
                const deleted_id : u32 = try buf_read_u32(&payload_ptr, &payload_left);
                std.log.info("\t↳ (deleted_id: {})\n", .{deleted_id});
            }
            else {
                std.log.info("\t↳ (unknown event, {} bytes ignored)", .{payload_left});
            }
            
            if(payload_left > 0) std.log.warn("↳ skipped {} bytes during event parsing", .{payload_left});
            moving_ptr += payload_size;
            msg_len -= payload_size;
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
