const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;

pub const PublicKey = struct {
    id: [8]u8,
    key: Ed25519.PublicKey,

    pub fn parse(encoded: []const u8) !PublicKey {
        if (encoded.len == 0) return error.ReleasePublicKeyNotConfigured;
        const raw = try decode(42, encoded);
        if (!std.mem.eql(u8, raw[0..2], "Ed")) return error.InvalidReleasePublicKey;
        return .{ .id = raw[2..10].*, .key = try Ed25519.PublicKey.fromBytes(raw[10..42].*) };
    }

    pub fn verify(
        self: PublicKey,
        io: std.Io,
        archive: []const u8,
        signature: []const u8,
        asset_name: []const u8,
    ) !void {
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, signature, "\r\n"), '\n');
        const untrusted = nextLine(&lines) orelse return error.InvalidReleaseSignature;
        if (!std.mem.startsWith(u8, untrusted, "untrusted comment: ")) return error.InvalidReleaseSignature;
        const raw = try decode(74, nextLine(&lines) orelse return error.InvalidReleaseSignature);
        if (!std.mem.eql(u8, raw[0..2], "ED")) return error.InvalidReleaseSignature;
        if (!std.mem.eql(u8, raw[2..10], &self.id)) return error.ReleaseSigningKeyMismatch;
        const trusted = nextLine(&lines) orelse return error.InvalidReleaseSignature;
        const comment = std.mem.cutPrefix(u8, trusted, "trusted comment: ") orelse return error.InvalidReleaseSignature;
        if (!std.mem.eql(u8, comment, asset_name)) return error.ReleaseSignatureAssetMismatch;
        const global = try decode(64, nextLine(&lines) orelse return error.InvalidReleaseSignature);
        if (lines.next() != null) return error.InvalidReleaseSignature;

        var comment_message: [64 + 4096]u8 = undefined;
        if (comment.len > comment_message.len - 64) return error.InvalidReleaseSignature;
        @memcpy(comment_message[0..64], raw[10..74]);
        @memcpy(comment_message[64..][0..comment.len], comment);
        try Ed25519.Signature.fromBytes(global).verify(comment_message[0 .. 64 + comment.len], self.key);

        const file = try std.Io.Dir.openFileAbsolute(io, archive, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        var hash = Blake2b512.init(.{});
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            const len = try reader.interface.readSliceShort(&chunk);
            if (len == 0) break;
            hash.update(chunk[0..len]);
        }
        const digest = hash.finalResult();
        try Ed25519.Signature.fromBytes(raw[10..74].*).verify(&digest, self.key);
    }
};

fn nextLine(lines: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    return std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
}

fn decode(comptime size: usize, encoded: []const u8) ![size]u8 {
    const decoder = std.base64.standard.Decoder;
    if ((decoder.calcSizeForSlice(encoded) catch return error.InvalidReleaseSignature) != size)
        return error.InvalidReleaseSignature;
    var bytes: [size]u8 = undefined;
    decoder.decode(&bytes, encoded) catch return error.InvalidReleaseSignature;
    return bytes;
}
