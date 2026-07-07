const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zprobe", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });
    mod.addIncludePath(b.path("deps/sqlite"));

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zprobe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zprobe", .module = mod },
            },
        }),
    });

    // Statically compile and link SQLite3 to default executable
    const sqlite_lib = b.addLibrary(.{
        .name = "sqlite3",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    sqlite_lib.root_module.addCSourceFile(.{
        .file = b.path("deps/sqlite/sqlite3.c"),
        .flags = &.{ "-std=c99", "-DSQLITE_DQS=0" },
    });
    sqlite_lib.root_module.addIncludePath(b.path("deps/sqlite"));
    sqlite_lib.root_module.linkSystemLibrary("c", .{});

    exe.root_module.linkLibrary(sqlite_lib);
    exe.root_module.addIncludePath(b.path("deps/sqlite"));
    exe.root_module.linkSystemLibrary("c", .{});

    b.installArtifact(exe);

    const server_exe = b.addExecutable(.{
        .name = "zprobe-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zprobe", .module = mod },
            },
        }),
    });
    server_exe.root_module.linkLibrary(sqlite_lib);
    server_exe.root_module.addIncludePath(b.path("deps/sqlite"));
    server_exe.root_module.linkSystemLibrary("c", .{});

    b.installArtifact(server_exe);

    // release-all step for building Apple Silicon and Synology NAS variants
    const release_all_step = b.step("release-all", "Build all production variants of zprobe");

    const targets = [_]struct {
        name: []const u8,
        query: std.Target.Query,
    }{
        .{ .name = "macos-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .name = "synology-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
        .{ .name = "synology-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
        .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } },
    };

    for (targets) |t| {
        const resolved_target = b.resolveTargetQuery(t.query);
        const variant_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = resolved_target,
            .optimize = .ReleaseSmall,
        });
        variant_mod.addIncludePath(b.path("deps/sqlite"));

        const variant_exe = b.addExecutable(.{
            .name = b.fmt("zprobe-{s}", .{t.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved_target,
                .optimize = .ReleaseSmall,
                .imports = &.{
                    .{ .name = "zprobe", .module = variant_mod },
                },
            }),
        });
        variant_exe.root_module.strip = true;

        const variant_sqlite = b.addLibrary(.{
            .name = b.fmt("sqlite3-{s}", .{t.name}),
            .root_module = b.createModule(.{
                .target = resolved_target,
                .optimize = .ReleaseSmall,
            }),
            .linkage = .static,
        });
        variant_sqlite.root_module.addCSourceFile(.{
            .file = b.path("deps/sqlite/sqlite3.c"),
            .flags = &.{ "-std=c99", "-DSQLITE_DQS=0" },
        });
        variant_sqlite.root_module.addIncludePath(b.path("deps/sqlite"));
        variant_sqlite.root_module.linkSystemLibrary("c", .{});

        variant_exe.root_module.linkLibrary(variant_sqlite);
        variant_exe.root_module.addIncludePath(b.path("deps/sqlite"));
        variant_exe.root_module.linkSystemLibrary("c", .{});

        const install_variant = b.addInstallArtifact(variant_exe, .{});
        release_all_step.dependOn(&install_variant.step);

        const variant_server_exe = b.addExecutable(.{
            .name = b.fmt("zprobe-server-{s}", .{t.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/server.zig"),
                .target = resolved_target,
                .optimize = .ReleaseSmall,
                .imports = &.{
                    .{ .name = "zprobe", .module = variant_mod },
                },
            }),
        });
        variant_server_exe.root_module.strip = true;

        variant_server_exe.root_module.linkLibrary(variant_sqlite);
        variant_server_exe.root_module.addIncludePath(b.path("deps/sqlite"));
        variant_server_exe.root_module.linkSystemLibrary("c", .{});

        const install_server_variant = b.addInstallArtifact(variant_server_exe, .{});
        release_all_step.dependOn(&install_server_variant.step);
    }

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    // Link SQLite3 to mod_tests as well since root.zig imports main.zig
    mod_tests.root_module.linkLibrary(sqlite_lib);
    mod_tests.root_module.linkSystemLibrary("c", .{});
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    // Link SQLite3 to the test executable as well
    exe_tests.root_module.linkLibrary(sqlite_lib);
    exe_tests.root_module.linkSystemLibrary("c", .{});
    
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
