//! Boot-scan behavior of the encrypted data volume ([B]).

const innigkeit = @import("innigkeit");
const std = @import("std");

test "encrypted volume: boot scan leaves a plaintext (GPT) boot disk unmounted" {
    // stage4's test setup ran mountAtBoot() before the suite. The test image's
    // only disk is the GPT boot disk (no INNIKVOL header) so the scan must
    // treat it as a plaintext volume (FDE off) and mount nothing. This is the
    // header-as-toggle property: encryption only engages on a provisioned disk.
    try std.testing.expect(innigkeit.filesystem.EncryptedVolume.bootVolume() == null);
}
