const std = @import("std");
const wl = @import("wayland.zig");
const linux = std.os.linux;

const usage =
    \\Usage: ./melatonina [options]
    \\
    \\Options:
    \\  -k [k]elvin_temperature
    \\
    \\Example: ./melatonina -k 4500
    \\
    \\Kelvin tips:
    \\ 5000K █░░░░░░░░░ Almost neutral
    \\ 4000K ███░░░░░░░ Slightly orange
    \\ 3000K ██████░░░░ Moderatly orange
    \\ 2000K █████████░ Strong orange
    \\
;

pub fn main(init: std.process.Init) !void {
    const kelvin = args_get_kelvin(init.minimal.args);

    const fd = try wl.display_connect(init.environ_map);
    defer _ = linux.close(fd);

    var client = wl.WaylandClient{
        .fd = fd,
    };

    client.wl_registry = try wl.wl_display_get_registry(&client);
    try wl.wait_for_sync(&client);

    try init_gamma(&client);
    client.gamma_control.?.table.set_kelvin(kelvin);
    try wl.zwlr_gamma_control_v1_set_gamma(&client);

    try wl.run_forever(&client);
}

fn args_get_kelvin(args: std.process.Args) u16 {
    var it = args.iterate();
    _ = it.next();
    
    const option = it.next() orelse fatal(usage, .{});
    if (!std.mem.eql(u8, option, "-k"))
        fatal(usage, .{});

    const value = it.next() orelse fatal(usage, .{});
    const kelvin = std.fmt.parseInt(u16, value, 10) 
        catch fatal("Error when parsing temperature: '{s}'", .{value});
    return kelvin;
}

fn init_gamma(client: *wl.WaylandClient) !void {
    const gamma_id = try wl.zwlr_gamma_control_manager_v1_get_gamma_control(client);
    const gamma_size = try wl.read_gamma_size(client, gamma_id);
    const gamma_table = try wl.mmap_gamma_table(gamma_size);

    client.gamma_control = .{
        .id = gamma_id,
        .size = gamma_size,
        .table = gamma_table,
    };

    // We init the gamma ramp to the identity ramp
    const maxU16 = std.math.maxInt(u16);
    for (0..gamma_size) |i| {
        const v: u16 = @intCast((i * maxU16) / (gamma_size - 1));
        gamma_table.data[0][i] = v;
        gamma_table.data[1][i] = v;
        gamma_table.data[2][i] = v;
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
