const std = @import("std");

pub fn isHeaderIteratorAuthorized(it: anytype, auth_user: []const u8, auth_pass: []const u8) bool {
    var iter = it;
    while (iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
            const prefix = "Basic ";
            if (std.mem.startsWith(u8, header.value, prefix)) {
                const creds_b64 = header.value[prefix.len..];
                const decoder = &std.base64.standard.Decoder;
                const decoded_size = decoder.calcSizeForSlice(creds_b64) catch return false;
                var decoded_buf: [512]u8 = undefined;
                if (decoded_size > decoded_buf.len) return false;
                decoder.decode(decoded_buf[0..decoded_size], creds_b64) catch return false;
                const decoded = decoded_buf[0..decoded_size];
                const colon_idx = std.mem.indexOfScalar(u8, decoded, ':') orelse return false;
                const decoded_user = decoded[0..colon_idx];
                const decoded_pass = decoded[colon_idx + 1 ..];
                return std.mem.eql(u8, decoded_user, auth_user) and std.mem.eql(u8, decoded_pass, auth_pass);
            }
        }
    }
    return false;
}

pub fn isRequestAuthorized(request: *const std.http.Server.Request, auth_user: []const u8, auth_pass: []const u8) bool {
    return isHeaderIteratorAuthorized(request.iterateHeaders(), auth_user, auth_pass);
}

test "isHeaderIteratorAuthorized authentication checks" {
    const raw_headers_ok = "GET / HTTP/1.1\r\nHost: localhost:8080\r\nAuthorization: Basic YWRtaW46cGFzc3dvcmQ=\r\n\r\n";
    const it_ok = std.http.HeaderIterator.init(raw_headers_ok);
    try std.testing.expect(isHeaderIteratorAuthorized(it_ok, "admin", "password"));

    const raw_headers_fail = "GET / HTTP/1.1\r\nHost: localhost:8080\r\nAuthorization: Basic YWRtaW46d3Jvbmc=\r\n\r\n";
    const it_fail = std.http.HeaderIterator.init(raw_headers_fail);
    try std.testing.expect(!isHeaderIteratorAuthorized(it_fail, "admin", "password"));

    const raw_headers_missing = "GET / HTTP/1.1\r\nHost: localhost:8080\r\n\r\n";
    const it_missing = std.http.HeaderIterator.init(raw_headers_missing);
    try std.testing.expect(!isHeaderIteratorAuthorized(it_missing, "admin", "password"));
}
