#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "root_uuid.h"

static void set_superblock_uuid(
    unsigned char superblock[AURA_EXT4_SUPERBLOCK_SIZE],
    const char *uuid) {
    size_t source = 0;
    size_t destination = 0;

    memset(superblock, 0, AURA_EXT4_SUPERBLOCK_SIZE);
    superblock[AURA_EXT4_MAGIC_OFFSET] = 0x53;
    superblock[AURA_EXT4_MAGIC_OFFSET + 1] = 0xef;

    while (source < AURA_UUID_TEXT_LENGTH) {
        int high;
        int low;

        if (uuid[source] == '-') {
            ++source;
            continue;
        }
        high = aura_hex_value(uuid[source]);
        low = aura_hex_value(uuid[source + 1]);
        assert(high >= 0 && low >= 0 && destination < 16);
        superblock[AURA_EXT4_UUID_OFFSET + destination] =
            (unsigned char)((high << 4) | low);
        ++destination;
        source += 2;
    }
    assert(destination == 16);
}

static void test_parse_root_uuid(void) {
    char uuid[AURA_UUID_STRING_SIZE];

    assert(aura_parse_root_uuid(
        "console=ttyS0 rdinit=/init root=UUID=01234567-89AB-CDEF-0123-456789ABCDEF",
        uuid) == 1);
    assert(strcmp(uuid, "01234567-89ab-cdef-0123-456789abcdef") == 0);
}

static void test_no_root_uuid_is_legacy_mode(void) {
    char uuid[AURA_UUID_STRING_SIZE];

    assert(aura_parse_root_uuid("console=ttyS0 rdinit=/init", uuid) == 0);
}

static void test_reject_malformed_or_ambiguous_root(void) {
    char uuid[AURA_UUID_STRING_SIZE];

    assert(aura_parse_root_uuid("root=UUID=not-a-uuid", uuid) == -1);
    assert(aura_parse_root_uuid("root=LABEL=AURA_ROOTFS", uuid) == -1);
    assert(aura_parse_root_uuid(
        "root=UUID=01234567-89ab-cdef-0123-456789abcdef "
        "root=UUID=01234567-89ab-cdef-0123-456789abcdef",
        uuid) == -1);
}

static void test_match_ext4_superblock_uuid(void) {
    unsigned char superblock[AURA_EXT4_SUPERBLOCK_SIZE];
    const char *uuid = "01234567-89ab-cdef-0123-456789abcdef";

    set_superblock_uuid(superblock, uuid);
    assert(aura_ext4_superblock_matches_uuid(superblock, uuid) == 1);
    assert(aura_ext4_superblock_matches_uuid(
        superblock, "11234567-89ab-cdef-0123-456789abcdef") == 0);

    superblock[AURA_EXT4_MAGIC_OFFSET] = 0;
    assert(aura_ext4_superblock_matches_uuid(superblock, uuid) == 0);
}

int main(void) {
    test_parse_root_uuid();
    test_no_root_uuid_is_legacy_mode();
    test_reject_malformed_or_ambiguous_root();
    test_match_ext4_superblock_uuid();
    puts("Aura initramfs root UUID tests passed.");
    return 0;
}
