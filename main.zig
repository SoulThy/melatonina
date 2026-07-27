const std = @import("std");
const linux = std.os.linux;

const wayland_wl_registry_event_global_opcode   : u16 = 0;
const wayland_wl_callback_event_done_opcode     : u16 = 0;
const wayland_display_object_id                 : u32 = 1;
const wayland_wl_display_get_registry_opcode    : u16 = 1;
const wayland_wl_display_event_error_opcode     : u16 = 0;
const wayland_wl_display_event_delete_id_opcode : u16 = 1;
const wayland_wl_display_sync_opcode            : u16 = 0;
const wayland_wl_registry_bind_opcode           : u16 = 0;

var wayland_rolling_object_id : u32 = 1;

const WaylandMessageHeader = extern struct {
    object_id       : u32 = undefined,
    size_and_opcode : u32 = undefined,
};

const WaylandClient = struct {
    fd             : linux.fd_t,
    next_object_id : u32 = 2,

    wl_registry                   : u32 = 0,
    wl_output                     : u32 = 0,
    zwlr_gamma_control_manager_v1 : u32 = 0,
    sync_id                       : u32 = 0,

    pub fn allocateId(self: *WaylandClient) u32 {
        const id = self.next_object_id;
        self.next_object_id += 1;
        return id;
    }
};

pub fn main(init: std.process.Init) !void {
    const fd = try wayland_display_connect(init.environ_map, init.gpa);
    defer _ = linux.close(fd);

    var client = WaylandClient{
        .fd = fd,
    };

    client.wl_registry = try wayland_wl_display_get_registry(&client);
    client.sync_id     = try wayland_wl_display_sync(&client);

    try wayland_read_event_message(&client);

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
///
/// ref: https://wayland.freedesktop.org/docs/book/Protocol.html#wire-format
/// ref: https://wayland-book.com/registry.html
pub fn wayland_send_request(fd: linux.fd_t, object_id: u32, opcode: u16, args: anytype) !void{
    const struct_info = @typeInfo(@TypeOf(args)).@"struct";
    const field_names = struct_info.field_names;
    const field_types = struct_info.field_types;

    var payload_size: usize = 0;
    inline for(field_types, field_names) |f_type, f_name| {
        switch(f_type) {
            []u8, []const u8 => payload_size += @field(args, f_name).len,
            else             => payload_size += @sizeOf(f_type),
        }
    }

    const total_size : u16 = @intCast(@sizeOf(WaylandMessageHeader) + payload_size);
    const header = WaylandMessageHeader{
        .object_id = object_id,
        .size_and_opcode = @as(u32, total_size) << 16 | opcode,
    };

    var buffer : [256]u8 = undefined;
    if(total_size > buffer.len) return error.BufferTooSmall;

    @memcpy(buffer[0..@sizeOf(WaylandMessageHeader)], std.mem.asBytes(&header));
    var offset : usize = @sizeOf(WaylandMessageHeader);

    inline for(field_types, field_names) |f_type, f_name| {
        const value = @field(args, f_name);
        switch(f_type) {
            []u8, []const u8 => {
                @memcpy(buffer[offset..(offset+value.len)], value);
                offset += value.len;
            },
            else => {
                const bytes = std.mem.asBytes(&value);
                @memcpy(buffer[offset..(offset+bytes.len)], bytes);
                offset += bytes.len;
            },
        }
    }

    const result = linux.sendto(fd, &buffer, total_size, linux.MSG.DONTWAIT, null, 0);
    if(linux.errno(result) != .SUCCESS) {
        std.log.err("errno: {}", .{linux.errno(result)});
        return error.WaylandSendToFailed;
    }
}

/// This function sends a wayland message to the connected socket to obtain a 
/// global registry object.
/// This is done by making a `get_registry` request to the `wl_display` interface. 
/// The function has the responsability of incrementing `wayland_rolling_object_id` 
/// before using it as `object_id` and then returning it to caller.
pub fn wayland_wl_display_get_registry(client: *WaylandClient) !u32 {

    const new_id = client.allocateId();

    try wayland_send_request(client.fd, wayland_display_object_id, wayland_wl_display_get_registry_opcode, .{new_id});

    std.log.info("wl_display@{}.get_registry: wl_registry={}", .{wayland_display_object_id, wayland_rolling_object_id});
    return new_id;
} 

/// This function sends a wayland message to the connected socket to send a 
/// sync request.
/// This sync object is then used when reading events to ensure
/// that all the information we expect to receive from the server
/// has been sent.
/// The function has the responsability of incrementing `wayland_rolling_object_id` 
/// before using it as `object_id` and then returning it to caller.
pub fn wayland_wl_display_sync(client: *WaylandClient) !u32 {
    const new_id = client.allocateId();

    try wayland_send_request(client.fd, wayland_display_object_id, wayland_wl_display_sync_opcode, .{new_id});

    std.log.info("wl_display@{}.sync: sync={}", .{wayland_display_object_id, wayland_rolling_object_id});
    return new_id;
} 

/// This function sends a wayland message to the connected socket to send a 
/// bind request.
/// This bind enables us to make requests to the just binded interface.
/// The function has the responsability of incrementing `wayland_rolling_object_id` 
/// before using it as `object_id` and then returning it to caller.
pub fn wayland_wl_registry_bind(client: *WaylandClient, name: u32, interface: [:0]const u8, version: u32) !u32 {
    const new_id = client.allocateId();

    var new_id_buffer : [128]u8 = undefined;
    var moving_ptr : [*]u8 = &new_id_buffer;
    var moving_len = new_id_buffer.len;

    try buf_write_string(&moving_ptr, &moving_len, interface);
    try buf_write_u32(&moving_ptr, &moving_len, version);
    try buf_write_u32(&moving_ptr, &moving_len, new_id);

    const used : usize = new_id_buffer.len - moving_len;

    try wayland_send_request(client.fd, client.wl_registry, wayland_wl_registry_bind_opcode, .{name,new_id_buffer[0..used]});

    std.log.info("wl_registry@{}.bind: name={} interface={s} version={} id={}", .{client.wl_registry, name, interface, version, new_id});

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
pub fn wayland_read_event_message(client: *WaylandClient) !void {
    var buffer : [4096]u8 = undefined;
    var synced = false;

    while(synced == false){
        const result = linux.recvfrom(client.fd, &buffer, buffer.len, 0, null, null);
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

            if(object_id == client.wl_registry and opcode == wayland_wl_registry_event_global_opcode){
                const name      : u32        = try buf_read_u32(&payload_ptr, &payload_left);
                const interface : [:0]const u8 = try buf_read_string(&payload_ptr, &payload_left);
                const version   : u32        = try buf_read_u32(&payload_ptr, &payload_left);
                std.log.info("\t↳ (name: {},interface: {s},version: {})", .{name, interface, version});

                // todo: this is starting to look like 'if' nesting hell, could
                // probably use a string hashmap instead. But for now will do.
                if(std.mem.eql(u8, interface, "wl_output")){
                    client.wl_output = try wayland_wl_registry_bind(client, name, interface, version);
                }
                else if(std.mem.eql(u8, interface, "zwlr_gamma_control_manager_v1")){
                    client.zwlr_gamma_control_manager_v1 = try wayland_wl_registry_bind(client, name, interface, version);
                }
            }
            else if(object_id == client.sync_id and opcode == wayland_wl_callback_event_done_opcode){
                const callback_data : u32 = try buf_read_u32(&payload_ptr, &payload_left);
                synced = true;
                std.log.info("\t↳ (callback_data: {})", .{callback_data});
            }
            else if(object_id == wayland_display_object_id and opcode == wayland_wl_display_event_delete_id_opcode){
                const deleted_id : u32 = try buf_read_u32(&payload_ptr, &payload_left);
                std.log.info("\t↳ (deleted_id: {})\n", .{deleted_id});
            }
            else if(object_id == wayland_display_object_id and opcode == wayland_wl_display_event_error_opcode){
                const bad_object_id : u32          = try buf_read_u32(&payload_ptr, &payload_left);
                const code          : u32          = try buf_read_u32(&payload_ptr, &payload_left);
                const message       : [:0]const u8 = try buf_read_string(&payload_ptr, &payload_left);
                std.log.err("\t↳ wl_display.error: object_id={} code={} message={s}", .{bad_object_id, code, message});
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

pub fn buf_write_string(buf: *[*]u8, buf_size: *usize, value: [:0]const u8) !void{
    // this length, has to include the null terminator.
    const length : u32 = @intCast(value.len + 1);
    const padding = (4 - (length % 4)) % 4;
    const total : usize = @sizeOf(u32) + length + padding;

    if(buf_size.* < total) return error.BufferSizeTooSmall;

    try buf_write_u32(buf, buf_size, length);

    const with_terminator = value[0..value.len + 1];
    @memcpy(buf.*[0..with_terminator.len], with_terminator);
    buf.* += with_terminator.len;
    buf_size.* -= with_terminator.len;

    @memset(buf.*[0..padding], 0);
    buf.* += padding;
    buf_size.* -= padding;
}

pub fn buf_write_u32(buf: *[*]u8, buf_size: *usize, value: u32) !void{
    if(buf_size.* < @sizeOf(u32)) return error.BufferSizeTooSmall;

    std.mem.writeInt(u32, buf.*[0..4], value, .little);
    buf.* += @sizeOf(u32);
    buf_size.* -= @sizeOf(u32);
}

pub fn buf_read_string(buf: *[*]u8, buf_size: *usize) ![:0]const u8{
    // this length, includes null terminator.
    const length = try buf_read_u32(buf, buf_size);

    if(length == 0) return "";
    if(buf_size.* < length) return error.BufferSizeTooSmall;

    const string : [:0]const u8 = buf.*[0..length-1 :0];
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
