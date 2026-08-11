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
