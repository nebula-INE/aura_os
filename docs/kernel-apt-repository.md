# Signed Aura kernel APT repository

Aura OS uses a dedicated OpenPGP key to authenticate the kernel APT repository.
This key is intentionally separate from the Ed25519 key used to sign installer
media. Installed systems trust only the configured keyring through the
repository's `Signed-By` field; they do not trust an unsigned repository or
disable APT authentication.

## Repository layout and client configuration

The repository is published at:

`https://nebula-INE.github.io/aura_os/apt`

Its distribution is `stable`, component `main`, and supported architectures
are `amd64`, `arm64`, and `riscv64`. Each architecture-specific Packages
index includes its matching kernel image package and the common
architecture-independent `aura-kernel` lifecycle package. The repository
metadata is published as signed `InRelease` and `Release.gpg` files.

Each versioned image package also installs a three-line metadata file recording
its target architecture, initramfs mode (`external` or `embedded`), and whether
loadable modules are present. The GRUB menu generator validates that exact
schema instead of sourcing the file as shell code; malformed metadata aborts
menu generation rather than being executed.

The base-rootfs builder installs the public key into
`/usr/share/keyrings/aura-kernel-archive-keyring.gpg` and creates
`/etc/apt/sources.list.d/aura-kernel.sources`. It restricts the source to the
target Debian architecture and this dedicated keyring.

## One-time repository setup

Generate a dedicated, offline-backed signing key. Do not reuse the installer
media signing key.

For example, create an Ed25519 signing key in a controlled environment:

```sh
gpg --quick-generate-key "Aura OS Kernel Repository <kernel-repo@YOUR_DOMAIN>" ed25519 sign 2y
gpg --list-secret-keys --keyid-format long
```

Export the public and private key material separately:

```sh
gpg --armor --export YOUR_FINGERPRINT > aura-kernel-repository-public.asc
gpg --armor --export-secret-keys YOUR_FINGERPRINT > aura-kernel-repository-private.asc
gpg --with-colons --fingerprint YOUR_FINGERPRINT
```

Keep the private export offline and tightly controlled. Add the following
repository-level Actions settings in GitHub:

| Setting | Type | Value |
|---|---|---|
| `AURA_APT_REPOSITORY_SIGNING_KEY_ASC` | Actions secret | Entire ASCII-armored private-key export |
| `AURA_APT_REPOSITORY_SIGNING_KEY_PASSPHRASE` | Actions secret | Optional passphrase for the private key; leave unset only when the key is unprotected |
| `AURA_APT_REPOSITORY_PUBLIC_KEY_ASC` | Actions variable | Entire ASCII-armored public-key export |
| `AURA_APT_REPOSITORY_FINGERPRINT` | Actions variable | Uppercase primary-key fingerprint from GPG |

The public fingerprint must match the public key and private key. The release
workflow refuses to publish if they do not match. Signing supports a
passphrase-protected private key through the separate passphrase secret. Do not
put the private key or passphrase in an Actions variable, repository file,
build artifact, or commit.

Enable GitHub Pages for the repository and configure it to deploy from the
`gh-pages` branch, root directory. The version-tag workflow writes the signed
repository under `apt/` on that branch. The first publication requires these
settings and the signing secret to exist; branch/PR CI uses a disposable test
key and never publishes it.

## Publishing a release

Push a version tag matching `v*` after the installer and QEMU matrix is green.
The release workflow downloads all three architecture package artifacts,
checks that package versions agree, regenerates architecture-filtered
indexes, signs the Release metadata, and publishes the cumulative repository.
Older kernel packages are retained so an installed machine can continue to
select a known-good image or install a specific older version.

## Verification and key rotation

The repository tests verify the detached and inline signatures, reject a
wrong signing key, and run `apt-get update` against a local file-based copy
using the dedicated `signed-by` keyring. Rootfs validation rejects a source
that is not HTTPS, targets another architecture, omits the dedicated keyring,
or disables signature verification.

Key rotation is deliberately not automatic. The repository builder rejects
publishing with a different key fingerprint while an existing repository is
present. Plan a rotation as a coordinated client trust update before changing
the publishing key; do not silently replace the repository key.
