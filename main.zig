const std = @import("std");
const wl = @import("wayland.zig");
const linux = std.os.linux;

pub fn main(init: std.process.Init) !void {
    const fd = try wl.display_connect(init.environ_map);
    defer _ = linux.close(fd);

    var client = wl.WaylandClient{
        .fd = fd,
    };

    client.wl_registry = try wl.wl_display_get_registry(&client);

    client.sync_id = try wl.wl_display_sync(&client);
    try wl.read_event_message(&client);

    client.zwlr_gamma_control_v1 = try wl.zwlr_gamma_control_manager_v1_get_gamma_control(&client);

    client.sync_id = try wl.wl_display_sync(&client);
    try wl.read_event_message(&client);

    try wl.zwlr_gamma_control_v1_set_gamma(&client);
    std.log.warn("size: {}", .{client.zwlr_gamma_size});
}
