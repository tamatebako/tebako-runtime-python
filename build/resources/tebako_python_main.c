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
 * 69 (no preload tier there) — unless the env image grants the spec 17
 * §7 materialize tier (TEBAKO_MATERIALIZE_BOOT: the driver extracted
 * every mounted image to a host tree, so the interpreter reads plain
 * host files and no visibility tier is needed). On that tier -E/-I in
 * the handed-off argv are refused with exit 2 (the flags would make
 * getpath ignore the driver-set PYTHONHOME — the only channel the
 * rewired root rides).
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
#include <windows.h>
#define setenv(name, value, overwrite) ((void)(overwrite), _putenv_s(name, value))

/* The interpreter argv the driver handed off (argv[0] is the resolved
 * entry, argv[1..] the user arguments, CPython's option grammar intact).
 * Returns 1 when -E or -I rides an option position: the flags make
 * getpath ignore the environment (Modules/getpath.py consults
 * ignore_environment for PYTHONHOME), and on the windows materialize
 * tier the runtime root RIDES the environment — the boot then falls
 * back to the baked prefix, which exists nowhere on the host, and dies
 * on the encodings import. Conservative by construction: only the
 * cluster-leading spelling is matched ("-sE" falls through to the old
 * cryptic init death, never to a wrong refusal); -c/-m consume the next
 * argument, so options end there; -X/-W take attached values and just
 * fall through the cluster walk. */
static int tebako_argv_carries_ignore_environment(int argc, char **argv) {
    int i;
    for (i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (arg[0] != '-' || arg[1] == '\0' || strcmp(arg, "--") == 0)
            return 0; /* the entry/script argument, stdin, or end of options */
        if (arg[1] == 'E' || arg[1] == 'I')
            return 1;
        if (arg[1] == 'c' || arg[1] == 'm')
            return 0; /* -c/-m take the next argument — options ended */
    }
    return 0;
}

/* The linked driver arms the handoff env with SetEnvironmentVariable
 * (Rust's std::env::set_var) — ucrt's getenv reads the CRT's startup
 * snapshot and never sees the driver's in-process writes, so on windows
 * every variable the boot may have (re)set — the spec 17 §7 rewired
 * TEBAKO_MOUNT_ROOT, the tier's TEBAKO_MATERIALIZE_BOOT marker, the
 * serialized TEBAKO_TFS_MOUNTS — is read through the Win32 API. Returns
 * the value's length; 0 means absent OR empty (the driver env filter's
 * own semantics — its respawn scrub blanks the pair). */
static DWORD tebako_win_env(const char *name, char *buf, DWORD cap) {
    return GetEnvironmentVariableA(name, buf, cap);
}
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

    /* PYTHONHOME from the EFFECTIVE mount root, read env-FIRST — the
     * ruby factory's era-2 pattern (rbconfig emits
     * ENV["TEBAKO_MOUNT_ROOT"] || <baked>): the driver's ffi mount point
     * is fixed before the windows materialize tier (spec 17 §7) rewires
     * TEBAKO_MOUNT_ROOT to the extracted env tree, so
     * tebako_mount_point() alone would strand PYTHONHOME on the baked
     * root (the interpreter then dies on the encodings import with
     * sys.prefix at the nonexistent baked tree). An empty override reads
     * as absent (the driver's respawn scrub blanks the pair). A bare exe
     * (no env image) is dev mode: PYTHONHOME stays untouched and getpath
     * resolves from the exe's own path. PYTHONPATH, when inherited, rides
     * along (the ruby runtime's RUBYLIB parity — the runtime never
     * scrubs it). */
    if (getenv("TEBAKO_RUNTIME_IMAGE") != NULL) {
#ifdef _WIN32
        /* The rewired root is the driver's own write — invisible to
         * ucrt's getenv; read it through the Win32 API (tebako_win_env).
         * A value past the cap is no usable mount root: fall back and
         * let getpath name the failure. */
        static char root_buf[32768];
        const char *root = tebako_win_env("TEBAKO_MOUNT_ROOT", root_buf, sizeof root_buf) > 0
            ? root_buf : tebako_mount_point();
#else
        const char *root = getenv("TEBAKO_MOUNT_ROOT");
        if (root == NULL || root[0] == '\0')
            root = tebako_mount_point();
#endif
        setenv("PYTHONHOME", root, 1);
    }

#ifdef _WIN32
    /* The materialize tier (spec 17 §7): the driver extracted every
     * mounted image into the exec cache and rewired TEBAKO_MOUNT_ROOT
     * (consumed above); the interpreter reads plain host files, so no
     * preload tier is needed. The in-process mounts still serialized
     * TEBAKO_TFS_MOUNTS — the tier's own marker, not the mount list,
     * gates the exit-69 refusal. Both reads go through tebako_win_env:
     * the driver set them in-process. */
    {
        char present[2];
        if (tebako_win_env("TEBAKO_MATERIALIZE_BOOT", present, sizeof present) > 0) {
            /* The env channel is load-bearing here (the root was rewired
             * to the extracted tree this boot): -E/-I are refused by
             * name instead of the interpreter dying on the encodings
             * import with stdlib dir at the baked, nonexistent prefix
             * (exit 2 — CPython's own usage-error code). POSIX never
             * takes this branch: there the preload shim serves the VFS
             * at the baked root path, so getpath resolves without the
             * environment and -E boots. */
            if (tebako_argv_carries_ignore_environment(argc, argv)) {
                fputs("tebako-python: -E/-I make the interpreter ignore the driver-set "
                      "PYTHONHOME — on the windows materialize tier (spec 17 §7) the runtime "
                      "root rides the environment, so the boot cannot resolve the stdlib; "
                      "drop the flag (environment hygiene belongs to the invoking shell)\n",
                      stderr);
                return 2;
            }
            return Py_BytesMain(argc, argv);
        }
        if (tebako_win_env("TEBAKO_TFS_MOUNTS", present, sizeof present) > 0) {
            fputs("tebako-python: the runtime mounted its filesystem image, but the env image "
                  "grants no windows boot tier (provides.windows_boot: materialize, spec 17 §7) "
                  "and windows has no preload visibility tier — the interpreter "
                  "cannot read the mounted tree\n", stderr);
            return 69;
        }
        return Py_BytesMain(argc, argv);
    }
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
