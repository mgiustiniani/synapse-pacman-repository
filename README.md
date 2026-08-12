# synapse-pacman-repository

Build and publish the packages whose `pkgname` starts with `synapse` from the
`cachyos-ai-integration` branch of CachyOS-PKGBUILDS.

## Rootless package creation

The default build path clones the `cachyos-ai-integration` branch, does not
elevate privileges, and does not install missing dependencies:

```sh
./build-synapse-pkgs.sh \
  --package synapse-rocm-runtime \
  --package synapse-comfyui-rocm
```

If an external dependency is missing, install it separately as part of a normal
full system upgrade, then rerun the build. Dependencies produced by other
packages selected in the same invocation are bootstrapped without installing
them on the host. `--syncdeps` is an explicit opt-in to makepkg's dependency
installation and may invoke the pacman authenticator. `--ignore-deps` is
available only for controlled packaging/debug builds.

`--pkgbuilds-dir` remains a development-only override for testing uncommitted
sources; production repository builds should omit it so PKGBUILDs are always
fetched from Git.

Use `--dry-run` to verify discovery and arguments without creating or publishing
packages. Binary outputs and the refreshed repository database are written to
`repo/x86_64/`.

## Resilient publication

PKGBUILD metadata, builds, and `repo-add` operations are isolated per package.
If one package fails, independent successful packages are still published and
the default exit status is successful; use `--strict` when any package failure
must fail the whole command. If nothing can be published, the command fails in
either mode.

Published filenames are immutable. A rebuild that changes an existing
`pkgname-pkgver-pkgrel` artifact is rejected: increment `pkgrel` (or `pkgver`)
before publishing it again. Packages larger than 100 MiB are also rejected so
the Pacman database cannot reference blobs that normal GitHub Git storage will
refuse. `SYNAPSE_MAX_PACKAGE_BYTES` can change that limit only when compatible
external storage has been configured.
