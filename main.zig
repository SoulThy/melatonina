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

    try init_gamma(&client);

    // now we should write the ramp! 
    // ...
    // and then call the set
    try wl.zwlr_gamma_control_v1_set_gamma(&client);
}

fn init_gamma(client: *wl.WaylandClient) !void {
    const gamma_id = try wl.zwlr_gamma_control_manager_v1_get_gamma_control(client);

    client.sync_id = try wl.wl_display_sync(client);
    const gamma_size = try wl.read_gamma_size(client, gamma_id);

    const gamma_table = try wl.mmap_gamma_table(gamma_size);

    client.gamma_control = .{
        .id = gamma_id,
        .size = gamma_size,
        .table = gamma_table,
    };
}

