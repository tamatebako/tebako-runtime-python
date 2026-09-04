/*
 * THIS FILE IS A TEMPLATE — the factory generates Programs/tebako_python.c
 * from it with @MOUNT_ROOT@ substituted (PythonBuild#write_fs_tu).
 *
 * The tebako python fs TU (translation unit): the runtime exe's real
 * main(), replacing Programs/python.o in the $(BUILDPYTHON) link. The
 * spec-17 driver is LINKED into the interpreter (the ruby pattern —
 * README's LINKED-driver decision), but unlike ruby the interpreter is
 * UNPATCHED (tamatebako/python's zero-patch contract): CPython's own file
 * IO cannot see the driver's mounts. The visibility story is spec 22's
 * tier-1 preload interposition, composed in two process incarnations:
 *
 *   1. the FIRST incarnation boots the driver in-process
 *      (tebako_driver_boot — mounts the env image from
 *      TEBAKO_RUNTIME_IMAGE and every --tebako-image payload triple,
 *      verifies the layout card, applies the jail, rewrites argv to the
 *      resolved entry, and arms the preload-shim injection env from the
 *      image's layout grant). A preload library binds only at exec, so —
 *   2. when the boot mounted anything, main re-execs ITSELF with the
 *      rewritten argv and the driver-armed env (LD_PRELOAD /
 *      DYLD_INSERT_LIBRARIES + TEBAKO_PRELOAD_SHIM + TEBAKO_TFS_MOUNTS).
 *      The shim's constructor re-mounts the serialized mount table in the
 *      child; the child (sentinel set) skips the boot and runs the
 *      interpreter, whose libc IO the shim now serves from the VFS.
 *
 * This is the linked-pattern analog of the spec-29 wrapper's
 * exec-with-preload and of the driver's own macOS micro-dylib
 * self-insert (which runs at the driver's boot head regardless).
 *
 * Boot contract (exit codes are the driver's, surfaced unmodified — the
 * same named errors the ruby runtime produces): TEBAKO_MOUNT_ROOT
 * malformed -> 65 (driver-validated pre-mount); ungranted override -> 78
 * (the layout pair check); a mounted image with no preload_shim grant ->
 * 78 (below: the interpreter would boot blind); windows with any mount ->
 * 69 (no preload tier there — roadmap 30 phase 2).
 */

/* glibc AND musl under -std=c11 (strict ANSI — CPython's default cflags,
 * and this TU includes no pyconfig.h) hide readlink/setenv behind
 * feature-test macros; _GNU_SOURCE exposes them. Must precede every
 * system include. macOS declares both regardless. */
#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <unistd.h>
#endif
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

/* ucrt has no POSIX setenv; _putenv_s overwrites unconditionally, which
 * is exactly what every call site below asks (overwrite=1). */
#ifdef _WIN32
#define setenv(name, value, overwrite) ((void)(overwrite), _putenv_s(name, value))
#endif

/* The spec-17 driver ABI (tamatebako/tebako crates/tebako-driver ffi.rs). */
extern int tebako_driver_boot(int *argc, char ***argv, const char *runtime_root);
extern const char *tebako_mount_point(void);
extern unsigned int tebako_driver_contract_version(void);

/* CPython's byte-argv entry (Programs/python.c's own call on POSIX; on
 * windows it decodes per the filesystem encoding — the v1 windows leg is
 * the driver-contract surface only, README's windows boundary). */
extern int Py_BytesMain(int argc, char **argv);

/* The mount root this runtime was compiled against. OWNER: this factory
 * (tamatebako/python carries no patch literals to flow it from); the
 * env image's layout card declares the same value, emitted from the same
 * constant in the same build. */
static const char tebako_python_mount_root[] = "@MOUNT_ROOT@";

/* The re-exec sentinel (the class comment). */
#define TEBAKO_PYTHON_BOOTED "TEBAKO_PYTHON_BOOTED"

#ifndef _WIN32
/* The running executable's own path for the re-exec: /proc on linux,
 * _NSGetExecutablePath on macOS (canonicalized — the shim's exec identity
 * is the resolved path), argv[0] as the last resort when it carries a
 * path separator. A failure is a named error, never a PATH guess. */
static int self_executable_path(char *buf, size_t cap, const char *argv0) {
#if defined(__linux__)
    ssize_t n = readlink("/proc/self/exe", buf, cap - 1);
    if (n <= 0 || (size_t)n >= cap - 1)
        return -1;
    buf[n] = '\0';
    return 0;
#elif defined(__APPLE__)
    uint32_t size = (uint32_t)cap;
    char resolved[PATH_MAX];
    if (_NSGetExecutablePath(buf, &size) != 0)
        return -1;
    if (realpath(buf, resolved) == NULL)
        return -1;
    if (strlen(resolved) >= cap)
        return -1;
    strcpy(buf, resolved);
    return 0;
#else
    (void)cap;
    if (strchr(argv0, '/') != NULL && realpath(argv0, buf) != NULL)
        return 0;
    return -1;
#endif
}
#endif

int main(int argc, char **argv) {
    int rc;
    char version[16];

    /* The re-exec'd child: the preload shim is armed and its constructor
     * has re-mounted the mount table — straight to the interpreter. */
    if (getenv(TEBAKO_PYTHON_BOOTED) != NULL)
        return Py_BytesMain(argc, argv);

    rc = tebako_driver_boot(&argc, &argv, tebako_python_mount_root);
    if (rc != 0)
        return rc; /* the named loader error is already on stderr; nothing mounted */

    /* The runtime is authoritative for the contract it speaks (the ruby
     * driver's tebako_main behavior — the generic tebako_driver_boot
     * entry leaves the export to the caller); an inherited value is
     * always overwritten. */
    snprintf(version, sizeof version, "%u", tebako_driver_contract_version());
    setenv("TEBAKO_CONTRACT_VERSION", version, 1);

    /* PYTHONHOME from the EFFECTIVE mount root (a TEBAKO_MOUNT_ROOT
     * override already applied by the driver) — the unpatched
     * interpreter's whole relocation story. A bare exe (no env image) is
     * dev mode: PYTHONHOME stays untouched and getpath resolves from the
     * exe's own path. PYTHONPATH, when inherited, rides along (the ruby
     * runtime's RUBYLIB parity — the runtime never scrubs it). */
    if (getenv("TEBAKO_RUNTIME_IMAGE") != NULL)
        setenv("PYTHONHOME", tebako_mount_point(), 1);

#ifdef _WIN32
    if (getenv("TEBAKO_TFS_MOUNTS") != NULL) {
        fputs("tebako-python: the runtime mounted its filesystem image, but the windows "
              "visibility tier is not implemented (roadmap 30 phase 2) — the interpreter "
              "cannot read the mounted tree\n", stderr);
        return 69;
    }
    return Py_BytesMain(argc, argv);
#else
    if (getenv("TEBAKO_TFS_MOUNTS") == NULL)
        return Py_BytesMain(argc, argv); /* bare boot — nothing mounted */

    if (getenv("TEBAKO_PRELOAD_SHIM") == NULL) {
        fputs("tebako-python: the env image declares no preload shim (lib/tebako/layout.yaml) — "
              "an unpatched CPython cannot read the mounted filesystem without it; rebuild the "
              "runtime with a link unit that ships libtfs_preload\n", stderr);
        return 78;
    }

    {
        char self[PATH_MAX];
        if (self_executable_path(self, sizeof self, argv[0]) != 0) {
            fputs("tebako-python: cannot resolve the interpreter's own path for the "
                  "preload-shim re-exec\n", stderr);
            return 74;
        }
        setenv(TEBAKO_PYTHON_BOOTED, "1", 1);
        execv(self, argv);
        perror("tebako-python: re-exec under the preload shim failed");
        return 74;
    }
#endif
}
