#ifndef AURA_INITRAMFS_ROOT_UUID_H
#define AURA_INITRAMFS_ROOT_UUID_H

#include <stddef.h>
#include <string.h>

#define AURA_UUID_TEXT_LENGTH 36
#define AURA_UUID_STRING_SIZE 37
#define AURA_EXT4_SUPERBLOCK_SIZE 1024
#define AURA_EXT4_SUPERBLOCK_OFFSET 1024
#define AURA_EXT4_MAGIC_OFFSET 56
#define AURA_EXT4_UUID_OFFSET 104

static inline int aura_hex_value(char value) {
    if (value >= '0' && value <= '9') {
        return value - '0';
    }
    if (value >= 'a' && value <= 'f') {
        return value - 'a' + 10;
    }
    if (value >= 'A' && value <= 'F') {
        return value - 'A' + 10;
    }
    return -1;
}

static inline int aura_normalize_uuid(const char *input,
                                      char output[AURA_UUID_STRING_SIZE]) {
    size_t index;

    if (input == NULL || strlen(input) != AURA_UUID_TEXT_LENGTH) {
        return -1;
    }

    for (index = 0; index < AURA_UUID_TEXT_LENGTH; ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (input[index] != '-') {
                return -1;
            }
            output[index] = '-';
        } else {
            int nibble = aura_hex_value(input[index]);
            if (nibble < 0) {
                return -1;
            }
            output[index] = "0123456789abcdef"[nibble];
        }
    }
    output[AURA_UUID_TEXT_LENGTH] = '\0';
    return 0;
}

/*
 * Return 1 for one valid root=UUID= argument, 0 when root= is absent,
 * and -1 for malformed, unsupported, or duplicate root= arguments.
 */
static inline int aura_parse_root_uuid(const char *command_line,
                                       char output[AURA_UUID_STRING_SIZE]) {
    const char *cursor;
    int found = 0;

    if (command_line == NULL || output == NULL) {
        return -1;
    }

    cursor = command_line;
    while (*cursor != '\0') {
        const char *token;
        size_t length;

        while (*cursor == ' ' || *cursor == '\t' ||
               *cursor == '\r' || *cursor == '\n') {
            ++cursor;
        }
        if (*cursor == '\0') {
            break;
        }

        token = cursor;
        while (*cursor != '\0' && *cursor != ' ' && *cursor != '\t' &&
               *cursor != '\r' && *cursor != '\n') {
            ++cursor;
        }
        length = (size_t)(cursor - token);

        if (length >= 5 && memcmp(token, "root=", 5) == 0) {
            char raw_uuid[AURA_UUID_STRING_SIZE];
            size_t value_length = length - 5;

            if (found || value_length <= 5 ||
                memcmp(token + 5, "UUID=", 5) != 0 ||
                value_length - 5 != AURA_UUID_TEXT_LENGTH) {
                return -1;
            }
            memcpy(raw_uuid, token + 10, AURA_UUID_TEXT_LENGTH);
            raw_uuid[AURA_UUID_TEXT_LENGTH] = '\0';
            if (aura_normalize_uuid(raw_uuid, output) != 0) {
                return -1;
            }
            found = 1;
        }
    }

    return found;
}

static inline int aura_ext4_superblock_matches_uuid(
    const unsigned char superblock[AURA_EXT4_SUPERBLOCK_SIZE],
    const char uuid[AURA_UUID_STRING_SIZE]) {
    unsigned char expected[16];
    size_t source = 0;
    size_t destination = 0;

    if (superblock == NULL || uuid == NULL ||
        superblock[AURA_EXT4_MAGIC_OFFSET] != 0x53 ||
        superblock[AURA_EXT4_MAGIC_OFFSET + 1] != 0xef) {
        return 0;
    }

    while (source < AURA_UUID_TEXT_LENGTH) {
        int high;
        int low;

        if (uuid[source] == '-') {
            ++source;
            continue;
        }
        if (source + 1 >= AURA_UUID_TEXT_LENGTH || destination >= sizeof(expected)) {
            return 0;
        }
        high = aura_hex_value(uuid[source]);
        low = aura_hex_value(uuid[source + 1]);
        if (high < 0 || low < 0) {
            return 0;
        }
        expected[destination++] = (unsigned char)((high << 4) | low);
        source += 2;
    }

    if (destination != sizeof(expected)) {
        return 0;
    }
    return memcmp(superblock + AURA_EXT4_UUID_OFFSET,
                  expected, sizeof(expected)) == 0;
}

#endif
