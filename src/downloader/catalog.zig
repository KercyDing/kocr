//! Available model packages published with kocr.

const std = @import("std");

pub const Package = struct {
    name: []const u8,
    cnb_url: []const u8,
    github_url: []const u8,
    sha256: []const u8,
};

pub const tiny = Package{
    .name = "ppocrv6-models-tiny.zip",
    .cnb_url = "https://cnb.cool/KercyDing/kocr/-/releases/download/ppocrv6-models/ppocrv6-models-tiny.zip",
    .github_url = "https://github.com/KercyDing/kocr/releases/download/ppocrv6-models/ppocrv6-models-tiny.zip",
    .sha256 = "4fb7887467c52fe2b036d3e875a91cea18c00cf9143427de45cb43054a5d7463",
};

pub const small = Package{
    .name = "ppocrv6-models-small.zip",
    .cnb_url = "https://cnb.cool/KercyDing/kocr/-/releases/download/ppocrv6-models/ppocrv6-models-small.zip",
    .github_url = "https://github.com/KercyDing/kocr/releases/download/ppocrv6-models/ppocrv6-models-small.zip",
    .sha256 = "8b83de7fcad297f183ebfa3e343cf551b7bfb2867ad0d1e78aa289e3ee769a4e",
};

pub const medium = Package{
    .name = "ppocrv6-models-medium.zip",
    .cnb_url = "https://cnb.cool/KercyDing/kocr/-/releases/download/ppocrv6-models/ppocrv6-models-medium.zip",
    .github_url = "https://github.com/KercyDing/kocr/releases/download/ppocrv6-models/ppocrv6-models-medium.zip",
    .sha256 = "2dd4bac64db833c5e7f89e05120c69528d304d12c3e8df08ed4f7c8e246090a4",
};

pub fn find(profile: []const u8) ?Package {
    if (std.mem.eql(u8, profile, "tiny")) return tiny;
    if (std.mem.eql(u8, profile, "small")) return small;
    if (std.mem.eql(u8, profile, "medium")) return medium;
    return null;
}
