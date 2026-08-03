const std = @import("std");
const linux = std.os.linux;

const WlDisplay = struct {
    const object_id: u32 = 1;

    const Request = enum(u16) {
        sync = 0,
        get_registry = 1,
    };

    const Event = enum(u16) {
        @"error" = 0,
        delete_id = 1,
    };
};

const WlRegistry = struct {
    const Request = enum(u16) {
        bind = 0,
    };

    const Event = enum(u16) {
        global = 0,
    };
};

const WlCallback = struct {
    const Event = enum(u16) {
        done = 0,
    };
};

const ZwlrGammaControlManagerV1 = struct {
    const Request = enum(u16) {
        get_gamma_control = 0,
    };
};

const WaylandMessageHeader = extern struct {
    object_id: u32 = undefined,
    size_and_opcode: u32 = undefined,
};

pub const WaylandClient = struct {
    fd: linux.fd_t,
    next_object_id: u32 = 2,

    wl_registry: u32 = 0,
    wl_output: u32 = 0,
    zwlr_gamma_control_manager_v1: u32 = 0,
    zwlr_gamma_control_v1: u32 = 0,
    sync_id: u32 = 0,

    pub fn allocateId(self: *WaylandClient) u32 {
        const id = self.next_object_id;
        self.next_object_id += 1;
        return id;
    }
};

/// This function creates and connects a Unix domain socket to enable
/// future communication with the wayland interface.
/// If successful, returns the file descriptor to the socket.
pub fn display_connect(env: *std.process.Environ.Map) !linux.fd_t {
    const xdg_runtime = env.get("XDG_RUNTIME_DIR") orelse return error.MissingXdgRuntimeDir;
    const wayland_display = env.get("WAYLAND_DISPLAY") orelse return error.MissingWaylandDisplay;

    const total_len = xdg_runtime.len + 1 + wayland_display.len;

    var addr = linux.sockaddr.un{
        .family = linux.AF.UNIX,
        .path = undefined,
    };

    if (total_len >= addr.path.len) return error.WaylandSocketPathTooLong;

    _ = try std.mem.print(&addr.path, "{s}/{s}", .{ xdg_runtime, wayland_display });

    var result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    const fd: linux.fd_t = switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => return error.SocketCreationFailed,
    };
    errdefer _ = linux.close(fd);

    const addr_len = @offsetOf(linux.sockaddr.un, "path") + total_len;
    result = linux.connect(fd, &addr, @intCast(addr_len));
    if (linux.errno(result) != .SUCCESS) return error.SocketConnectionFailed;

    std.log.info("fd to socket: {}", .{fd});
    return fd;
}

/// This functions sends a request to the socket pointed by
/// the file descriptor following the wire protocol format.
///
/// ref: https://wayland.freedesktop.org/docs/book/Protocol.html#wire-format
/// ref: https://wayland-book.com/registry.html
fn send_request(fd: linux.fd_t, object_id: u32, opcode: anytype, args: anytype) !void {
    const raw_opcode: u16 = switch (@typeInfo(@TypeOf(opcode))) {
        .@"enum" => @intFromEnum(opcode),
        .comptime_int, .int => @intCast(opcode),
        else => @compileError("invalid opcode, it has to be of type enum or int"),
    };

    const struct_info = @typeInfo(@TypeOf(args)).@"struct";
    const field_names = struct_info.field_names;
    const field_types = struct_info.field_types;

    var payload_size: usize = 0;
    inline for (field_types, field_names) |f_type, f_name| {
        switch (f_type) {
            []u8, []const u8 => payload_size += @field(args, f_name).len,
            else => payload_size += @sizeOf(f_type),
        }
    }

    const total_size: u16 = @intCast(@sizeOf(WaylandMessageHeader) + payload_size);
    const header = WaylandMessageHeader{
        .object_id = object_id,
        .size_and_opcode = @as(u32, total_size) << 16 | raw_opcode,
    };

    var buffer: [256]u8 = undefined;
    if (total_size > buffer.len) return error.BufferTooSmall;

    @memcpy(buffer[0..@sizeOf(WaylandMessageHeader)], std.mem.asBytes(&header));
    var offset: usize = @sizeOf(WaylandMessageHeader);

    inline for (field_types, field_names) |f_type, f_name| {
        const value = @field(args, f_name);
        switch (f_type) {
            []u8, []const u8 => {
                @memcpy(buffer[offset..(offset + value.len)], value);
                offset += value.len;
            },
            else => {
                const bytes = std.mem.asBytes(&value);
                @memcpy(buffer[offset..(offset + bytes.len)], bytes);
                offset += bytes.len;
            },
        }
    }

    const result = linux.sendto(fd, &buffer, total_size, linux.MSG.DONTWAIT, null, 0);
    if (linux.errno(result) != .SUCCESS) {
        std.log.err("errno: {}", .{linux.errno(result)});
        return error.WaylandSendToFailed;
    }
}

/// This function reads a wayland event message from the connected socket following
/// the wire protocol format.
/// This is done by performing a blocking read on the socket using a 4096 bytes
/// buffer (not optimal solution), then consuming the message header to obtain
/// the `object_id`, message size and event opcode before decoding the payload
/// based on the received event.
/// It keeps reading using syscalls (not optimal, should use shared memory)
/// untils the sync event gets returned.
pub fn read_event_message(client: *WaylandClient) !void {
    var buffer: [4096]u8 = undefined;
    var synced = false;
    var bytes_in_buffer: usize = 0;

    while (!synced) {
        const result = linux.recvfrom(client.fd, buffer[bytes_in_buffer..].ptr, buffer.len - bytes_in_buffer, 0, null, null);
        if (linux.errno(result) != .SUCCESS) return error.SocketConsumeWaylandHeaderFailed;

        bytes_in_buffer += result;
        var cursor: usize = 0;

        while ((bytes_in_buffer - cursor) >= 8) {
            const message_start = cursor;

            var header_reader = std.Io.Reader.fixed(buffer[message_start .. message_start + 8]);

            const object_id: u32 = try buf_read_u32(&header_reader);
            const size_and_opcode: u32 = try buf_read_u32(&header_reader);
            const size: u16 = @truncate(size_and_opcode >> 16);
            const opcode: u16 = @truncate(size_and_opcode);

            if (size < 8) return error.InvalidWaylandMessageSize;

            const message_end = message_start + size;

            // if this happens, we should proceed with circular buffer
            // procedure, to give space for information in the buffer.
            if (bytes_in_buffer < message_end) break;

            const payload_start = message_start + 8;
            const raw_payload = buffer[payload_start..message_end];

            try event_dispatch(client, object_id, opcode, raw_payload, &synced);

            cursor = message_end;
        }

        if (cursor < bytes_in_buffer) {
            const remaining = bytes_in_buffer - cursor;
            @memmove(buffer[0..remaining], buffer[cursor..bytes_in_buffer]);
            bytes_in_buffer = remaining;
        } else {
            bytes_in_buffer = 0;
        }
    }
}

/// This function uses object_id to determine the interface
/// and opcode to determine the event to parse and interpret
fn event_dispatch(client: *WaylandClient, object_id: u32, opcode: u16, raw_payload: []const u8, synced: *bool) !void {
    var payload_reader = std.Io.Reader.fixed(raw_payload);

    std.log.info("", .{});
    std.log.info("object_id {d:>10}\t size {d:>6}\t opcode {d:>6}", .{ object_id, raw_payload.len + 8, opcode });

    if (object_id == client.wl_registry) {
        switch (@as(WlRegistry.Event, @enumFromInt(opcode))) {
            .global => {
                const name: u32 = try buf_read_u32(&payload_reader);
                const interface: [:0]const u8 = try buf_read_string(&payload_reader);
                const version: u32 = try buf_read_u32(&payload_reader);
                std.log.info("\t↳ (name: {},interface: {s},version: {})", .{ name, interface, version });
                // todo: this is starting to look like 'if' nesting hell, could
                // probably use a string hashmap instead. But for now will do.
                if (std.mem.eql(u8, interface, "wl_output")) {
                    client.wl_output = try wl_registry_bind(client, name, interface, version);
                } else if (std.mem.eql(u8, interface, "zwlr_gamma_control_manager_v1")) {
                    client.zwlr_gamma_control_manager_v1 = try wl_registry_bind(client, name, interface, version);
                }
            },
        }
    } else if (object_id == client.sync_id) {
        switch (@as(WlCallback.Event, @enumFromInt(opcode))) {
            .done => {
                const callback_data: u32 = try buf_read_u32(&payload_reader);
                synced.* = true;
                std.log.info("\t↳ (callback_data: {})", .{callback_data});
            },
        }
    } else if (object_id == WlDisplay.object_id) {
        switch (@as(WlDisplay.Event, @enumFromInt(opcode))) {
            .@"error" => {
                const bad_object_id: u32 = try buf_read_u32(&payload_reader);
                const code: u32 = try buf_read_u32(&payload_reader);
                const message: [:0]const u8 = try buf_read_string(&payload_reader);
                std.log.err("\t↳ wl_display.error: object_id={} code={} message={s}", .{ bad_object_id, code, message });
            },
            .delete_id => {
                const deleted_id: u32 = try buf_read_u32(&payload_reader);
                std.log.info("\t↳ (deleted_id: {})\n", .{deleted_id});
            },
        }
    } else {
        std.log.err("\t↳ (unknown event)", .{});
    }
}

/// This function sends a wayland message to the connected socket to obtain a
/// global registry object.
/// This is done by making a `get_registry` request to the `wl_display` interface.
/// The function has the responsability of calling .allocateId();
/// before using it as `object_id` and then returning it to caller.
pub fn wl_display_get_registry(client: *WaylandClient) !u32 {
    const new_id = client.allocateId();

    try send_request(client.fd, WlDisplay.object_id, WlDisplay.Request.get_registry, .{new_id});

    std.log.info("wl_display@{}.get_registry: wl_registry={}", .{ WlDisplay.object_id, new_id });
    return new_id;
}

/// This function sends a wayland message to the connected socket to send a
/// sync request.
/// This sync object is then used when reading events to ensure
/// that all the information we expect to receive from the server
/// has been sent.
/// The function has the responsability of calling .allocateId();
/// before using it as `object_id` and then returning it to caller.
pub fn wl_display_sync(client: *WaylandClient) !u32 {
    const new_id = client.allocateId();

    try send_request(client.fd, WlDisplay.object_id, WlDisplay.Request.sync, .{new_id});

    std.log.info("wl_display@{}.sync: sync={}", .{ WlDisplay.object_id, new_id });
    return new_id;
}

/// This function sends a wayland message to the connected socket to send a
/// bind request.
/// Binding enables us to use the object we just binded to.
/// The function has the responsability of calling .allocateId();
/// before using it as `object_id` and then returning it to caller.
pub fn wl_registry_bind(client: *WaylandClient, name: u32, interface: [:0]const u8, version: u32) !u32 {
    const new_id = client.allocateId();

    var buffer: [128]u8 = undefined;

    var writer = std.Io.Writer.fixed(&buffer);
    try buf_write_string(&writer, interface);
    try buf_write_u32(&writer, version);
    try buf_write_u32(&writer, new_id);

    const full_new_id = writer.buffer[0..writer.end];

    try send_request(client.fd, client.wl_registry, WlRegistry.Request.bind, .{ name, full_new_id });


    return new_id;
}

/// This function sends a wayland message to the connected socket to send a
/// request to obtain the gamma_control_v1 object.
/// This object lets us "adjust gamma tables for an output".
/// The function has the responsability of calling .allocateId();
/// before using it as `object_id` and then returning it to caller.
pub fn zwlr_gamma_control_manager_v1_get_gamma_control(client: *WaylandClient) !u32 {
    if (client.zwlr_gamma_control_manager_v1 == 0) return error.ZwlrInterfaceNotFound;
    if (client.wl_output == 0) return error.WlOuotputInterfaceNotFound;

    const new_id = client.allocateId(); 

    try send_request(client.fd, client.zwlr_gamma_control_manager_v1, ZwlrGammaControlManagerV1.Request.get_gamma_control, .{new_id, client.wl_output});

    std.log.info("zwlr_gamma_get_control_manager_v1@{}.get_gamma_control: get_gamma_control={}", .{ client.zwlr_gamma_control_manager_v1, new_id });
    return new_id;
}

// ================= formatting helper functions =====================

fn buf_write_u32(writer: *std.Io.Writer, value: u32) !void {
    try writer.writeInt(u32, value, .little);
}

fn buf_write_string(writer: *std.Io.Writer, str: [:0]const u8) !void {
    // this length, includes null terminator.
    const len: u32 = @intCast(str.len + 1);
    const padding = (4 - (len % 4)) % 4;
    const zeroes = [3]u8{ 0, 0, 0 };

    try writer.writeInt(u32, len, .little);
    try writer.writeAll(str[0 .. str.len + 1]);
    try writer.writeAll(zeroes[0..padding]);
}

fn buf_read_u32(reader: *std.Io.Reader) !u32 {
    return try reader.takeInt(u32, .little);
}

fn buf_read_string(reader: *std.Io.Reader) ![:0]const u8 {
    // this length, includes null terminator.
    const len = try buf_read_u32(reader);
    const string: [:0]const u8 = try reader.takeSentinel(0);
    const padding = (4 - (len % 4)) % 4;
    reader.toss(padding);

    return string;
}
